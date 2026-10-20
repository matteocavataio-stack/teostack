import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Un file verificato da inserire nella ASC MHL.
public struct MHLFileEntry: Equatable {
    public var relativePath: String      // con "/", relativo alla cartella radice
    public var size: Int64
    public var modified: Date
    public var xxh64: String
    public var hashDate: Date

    public init(relativePath: String, size: Int64, modified: Date, xxh64: String, hashDate: Date) {
        self.relativePath = relativePath
        self.size = size
        self.modified = modified
        self.xxh64 = xxh64
        self.hashDate = hashDate
    }
}

public struct MHLOptions {
    public var author: String?
    public var location: String?
    public var comment: String?
    public var toolName = "TeoStackXt"
    public var toolVersion = "0.1.0"
    public var hostName = ProcessInfo.processInfo.hostName
    public var now = Date()
    public init() {}
}

public struct MHLOutput: Equatable {
    public var mhlPath: String
    public var chainPath: String
    public var generation: Int
    public var fileCount: Int
    public var failedFiles: [String]      // file il cui hash è diverso da quello di una generazione precedente
}

/// Scrive una generazione ASC MHL v2.0 (https://mediahashlist.org) in `<radice>/ascmhl/`, con hash XXH64, hash di directory
/// (content/structure) e catena `ascmhl_chain.xml` con ID C4. Il formato è stato verificato con lo strumento ufficiale `ascmhl`.
public enum ASCMHL {
    public static let folderName = "ascmhl"
    public static let chainFileName = "ascmhl_chain.xml"

    // MARK: Hash di directory (stesso algoritmo di ascmhl)

    private static func hashData(_ data: [UInt8]) -> String {
        let h = XXH64Hasher()
        data.withUnsafeBytes { if let b = $0.baseAddress { h.update(b, count: data.count) } }
        return h.hexDigest()
    }

    private static func bytes(ofHex hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return out
    }

    /// Hash dell'elenco di hash: ordinamento lessicografico delle stringhe, poi XXH64 dei byte concatenati (lista vuota → hash del vuoto).
    private static func hashOfList(_ list: [String]) -> String {
        let h = XXH64Hasher()
        for s in list.sorted() {
            let b = bytes(ofHex: s)
            b.withUnsafeBytes { if let base = $0.baseAddress { h.update(base, count: b.count) } }
        }
        return h.hexDigest()
    }

    private struct DirNode {
        var path: String
        var files: [MHLFileEntry] = []
        var dirs: [String] = []          // percorsi dei figli
    }

    /// (content, structure) di una directory, calcolati ricorsivamente.
    private static func directoryHashes(_ path: String, nodes: [String: DirNode], cache: inout [String: (String, String)]) -> (String, String) {
        if let c = cache[path] { return c }
        let node = nodes[path] ?? DirNode(path: path)
        var content: [String] = [], structure: [String] = []
        for f in node.files {
            content.append(f.xxh64)
            structure.append(hashData(Array((f.relativePath as NSString).lastPathComponent.utf8) + bytes(ofHex: f.xxh64)))
        }
        for d in node.dirs {
            let (c, s) = directoryHashes(d, nodes: nodes, cache: &cache)
            content.append(c)
            structure.append(hashData(Array((d as NSString).lastPathComponent.utf8) + bytes(ofHex: s)))
        }
        let result = (hashOfList(content), hashOfList(structure))
        cache[path] = result
        return result
    }

    // MARK: Date

    private static func isoString(_ d: Date, fraction: Bool, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = fraction ? "yyyy-MM-dd'T'HH:mm:ss.SSSxxxxx" : "yyyy-MM-dd'T'HH:mm:ssxxxxx"
        return f.string(from: d)
    }

    private static func fileNameDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f.string(from: d) + "Z"
    }

    private static func esc(_ s: String) -> String { ReportExporter.xmlEscape(s) }

    // MARK: Scrittura

    /// Scrive la prossima generazione. Non modifica né cancella nulla di ciò che esiste già (le generazioni precedenti restano intatte).
    public static func write(root: URL, files rawFiles: [MHLFileEntry], options: MHLOptions = MHLOptions()) throws -> MHLOutput {
        let rootPath = root.standardizedFileURL.path
        guard !rawFiles.isEmpty else { throw MetadataError.invalidOutput("Nessun file verificato da inserire nella ASC MHL.") }
        let files = rawFiles.sorted { $0.relativePath < $1.relativePath }

        let folder = (rootPath as NSString).appendingPathComponent(folderName)
        let chainPath = (folder as NSString).appendingPathComponent(chainFileName)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)

        // generazioni precedenti
        var generations: [(number: Int, path: String, c4: String)] = []
        if let chainText = try? String(contentsOfFile: chainPath, encoding: .utf8) { generations = parseChain(chainText) }
        let nextNumber = (generations.map(\.number).max() ?? 0) + 1
        var previous: [String: String] = [:]
        for g in generations {
            for (path, hash) in parseHashList(at: (folder as NSString).appendingPathComponent(g.path)) where previous[path] == nil { previous[path] = hash }
        }

        // struttura delle directory
        var nodes: [String: DirNode] = ["": DirNode(path: "")]
        for f in files {
            let dir = (f.relativePath as NSString).deletingLastPathComponent
            var d = dir
            nodes[d, default: DirNode(path: d)].files.append(f)
            while !d.isEmpty {
                let parent = (d as NSString).deletingLastPathComponent
                if nodes[parent] == nil { nodes[parent] = DirNode(path: parent) }
                if !nodes[parent]!.dirs.contains(d) { nodes[parent]!.dirs.append(d) }
                d = parent
            }
        }
        for key in nodes.keys { nodes[key]!.dirs.sort() }
        var cache: [String: (String, String)] = [:]
        let rootHashes = directoryHashes("", nodes: nodes, cache: &cache)

        // XML della generazione
        let rootDate = isoString(options.now, fraction: true)
        var failed: [String] = []
        var x = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<hashlist version=\"2.0\" xmlns=\"urn:ASC:MHL:v2.0\">\n"
        x += "  <creatorinfo>\n    <creationdate>\(isoString(options.now, fraction: false))</creationdate>\n    <hostname>\(esc(options.hostName))</hostname>\n"
        x += "    <tool version=\"\(esc(options.toolVersion))\">\(esc(options.toolName))</tool>\n"
        if let a = options.author?.trimmingCharacters(in: .whitespaces), !a.isEmpty { x += "    <author>\(esc(a))</author>\n" }
        if let l = options.location, !l.isEmpty { x += "    <location>\(esc(l))</location>\n" }
        if let c = options.comment, !c.isEmpty { x += "    <comment>\(esc(c))</comment>\n" }
        x += "  </creatorinfo>\n  <processinfo>\n    <process>in-place</process>\n    <roothash>\n"
        x += "      <content>\n        <xxh64 hashdate=\"\(rootDate)\">\(rootHashes.0)</xxh64>\n      </content>\n"
        x += "      <structure>\n        <xxh64 hashdate=\"\(rootDate)\">\(rootHashes.1)</xxh64>\n      </structure>\n    </roothash>\n"
        x += "    <ignore>\n      <pattern>.DS_Store</pattern>\n      <pattern>ascmhl</pattern>\n      <pattern>ascmhl/</pattern>\n    </ignore>\n  </processinfo>\n  <hashes>\n"

        func fileElement(_ f: MHLFileEntry) -> String {
            var action = "original"
            if let old = previous[f.relativePath] {
                if old == f.xxh64 { action = "verified" } else { action = "failed"; failed.append(f.relativePath) }
            }
            return "    <hash>\n      <path size=\"\(f.size)\" lastmodificationdate=\"\(isoString(f.modified, fraction: false))\">\(esc(f.relativePath))</path>\n"
                + "      <xxh64 action=\"\(action)\" hashdate=\"\(isoString(f.hashDate, fraction: true))\">\(f.xxh64)</xxh64>\n    </hash>\n"
        }
        func emit(_ dirPath: String) {
            let node = nodes[dirPath]!
            for f in node.files { x += fileElement(f) }
            for d in node.dirs {
                emit(d)
                let (c, s) = cache[d]!
                let modified = (try? DiskIO.lstatInfo(path: (rootPath as NSString).appendingPathComponent(d)).times.modification) ?? options.now
                x += "    <directoryhash>\n      <path lastmodificationdate=\"\(isoString(modified, fraction: false))\">\(esc(d))</path>\n"
                x += "      <content>\n        <xxh64 hashdate=\"\(rootDate)\">\(c)</xxh64>\n      </content>\n"
                x += "      <structure>\n        <xxh64 hashdate=\"\(rootDate)\">\(s)</xxh64>\n      </structure>\n    </directoryhash>\n"
            }
        }
        emit("")
        x += "  </hashes>\n</hashlist>\n"

        let baseName = (rootPath as NSString).lastPathComponent
        let mhlName = String(format: "%04d_%@_%@.mhl", nextNumber, baseName, fileNameDate(options.now))
        let mhlPath = (folder as NSString).appendingPathComponent(mhlName)
        if FileManager.default.fileExists(atPath: mhlPath) {
            throw DiskIOError(code: EEXIST, operation: "File ASC MHL già presente", path: mhlPath)
        }
        let mhlData = Data(x.utf8)
        try mhlData.write(to: URL(fileURLWithPath: mhlPath), options: .withoutOverwriting)

        // catena
        generations.append((nextNumber, mhlName, C4.id(of: mhlData)))
        var chain = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<ascmhldirectory xmlns=\"urn:ASC:MHL:DIRECTORY:v2.0\">\n"
        for g in generations {
            chain += "  <hashlist sequencenr=\"\(g.number)\">\n    <path>\(esc(g.path))</path>\n    <c4>\(g.c4)</c4>\n  </hashlist>\n"
        }
        chain += "</ascmhldirectory>\n"
        try Data(chain.utf8).write(to: URL(fileURLWithPath: chainPath), options: .atomic)

        return MHLOutput(mhlPath: mhlPath, chainPath: chainPath, generation: nextNumber, fileCount: files.count, failedFiles: failed)
    }

    // MARK: Lettura delle generazioni precedenti

    private final class ChainParser: NSObject, XMLParserDelegate {
        var generations: [(number: Int, path: String, c4: String)] = []
        private var number = 0, path = "", c4 = "", element = "", text = ""
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
            element = name; text = ""
            if name == "hashlist" { number = Int(attributes["sequencenr"] ?? "") ?? 0; path = ""; c4 = "" }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if name == "path" { path = t } else if name == "c4" { c4 = t }
            else if name == "hashlist" { generations.append((number, path, c4)) }
        }
    }

    static func parseChain(_ text: String) -> [(number: Int, path: String, c4: String)] {
        let p = ChainParser()
        let parser = XMLParser(data: Data(text.utf8))
        parser.delegate = p
        parser.parse()
        return p.generations
    }

    private final class HashListParser: NSObject, XMLParserDelegate {
        var hashes: [String: String] = [:]
        private var inHash = false, inDirectory = false, path = "", text = ""
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
            text = ""
            if name == "hash" { inHash = true; path = "" }
            if name == "directoryhash" { inDirectory = true }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if inHash && name == "path" { path = t }
            if inHash && name == "xxh64" && hashes[path] == nil { hashes[path] = t }
            if name == "hash" { inHash = false }
            if name == "directoryhash" { inDirectory = false }
        }
    }

    static func parseHashList(at path: String) -> [String: String] {
        guard let data = FileManager.default.contents(atPath: path) else { return [:] }
        let p = HashListParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        return p.hashes
    }
}
