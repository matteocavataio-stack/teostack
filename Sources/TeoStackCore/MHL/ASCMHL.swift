import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Nome e versione del programma (scritti nel file MHL).
public enum AppInfo {
    public static let name = "TeoStackXt"
    public static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
    }
}

public struct ASCMHLOptions {
    /// Nome di chi ha eseguito la copia (campo «author» del MHL); nil = nessun autore.
    public var author: String?
    public var comment: String?
    public init(author: String? = nil, comment: String? = nil) {
        let trimmed = author?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.author = (trimmed?.isEmpty ?? true) ? nil : trimmed
        self.comment = comment
    }
}

/// Esito per destinazione.
public enum ASCMHLOutcome: Equatable {
    /// Generazione scritta: cartella `ascmhl`, nome del file .mhl, numero di generazione e file elencati.
    case written(folder: String, file: String, generation: Int, files: Int)
    /// Non creato (con il motivo): per esempio perché ci sono file non verificati OK.
    case skipped(String)
    case failed(String)
}

public struct ASCMHLWriteResult: Equatable {
    public let folder: URL
    public let file: URL
    public let generation: Int
    public let fileCount: Int
    /// File non nell'offload ma già presenti nella cartella: riletti per calcolare gli hash delle cartelle.
    public let rehashedCount: Int
    public let rootContentHash: String
    public let rootStructureHash: String
}

public enum ASCMHLError: Error, CustomStringConvertible, Equatable {
    case unreadableHistory(String)
    case invalidPath(String)
    case cancelled

    public var description: String {
        switch self {
        case .unreadableHistory(let m): return tr("La cronologia ASC MHL già presente nella cartella non si legge: {0}", m)
        case .invalidPath(let p): return tr("Il nome «{0}» contiene caratteri non ammessi in un file XML.", p)
        case .cancelled: return tr("Annullato.")
        }
    }
}

/// Scrive una nuova generazione ASC MHL 2.0 (https://github.com/ascmitc/mhl-specification) nella cartella `ascmhl` dentro la cartella della copia:
/// `ascmhl/NNNN_<cartella>_<data>_<ora>Z.mhl` + `ascmhl/ascmhl_chain.xml`.
///
/// Gli hash dei file sono XXH64 (esadecimale canonico). Per i file dell'offload si usano gli hash già calcolati e verificati dal motore;
/// gli altri file presenti nella cartella vengono riletti. Gli hash delle cartelle (content e structure) seguono l'algoritmo dello strumento ufficiale `ascmhl`.
/// Processo «transfer»; azione «original» (primo hash registrato), «verified» (uguale a una generazione precedente) o «failed» (diverso).
/// Scrive solo dentro `ascmhl`: non tocca i file della copia e non sovrascrive mai un MHL esistente.
public enum ASCMHLWriter {
    public static let folderName = "ascmhl"
    public static let chainFileName = "ascmhl_chain.xml"
    /// Pattern ignorati (come lo strumento ufficiale): non entrano negli hash.
    static let ignoredNames: Set<String> = [".DS_Store", folderName]

    public static func write(root: URL, knownHashes: [String: String], options: ASCMHLOptions = ASCMHLOptions(),
                             now: Date = Date(), isCancelled: () -> Bool = { false }) throws -> ASCMHLWriteResult {
        let rootPath = root.standardizedFileURL.path
        let ascPath = rootPath + "/" + folderName
        let fm = FileManager.default

        // 1. cronologia esistente (generazioni precedenti)
        var generation = 1
        var previous: [String: String] = [:]
        var chainEntries: [(sequence: Int, path: String, c4: String)] = []
        if fm.fileExists(atPath: ascPath) {
            let chainPath = ascPath + "/" + chainFileName
            if fm.fileExists(atPath: chainPath) {
                chainEntries = try readChain(path: chainPath)
                for entry in chainEntries.sorted(by: { $0.sequence < $1.sequence }) {
                    for (path, hash) in try readHashes(path: ascPath + "/" + entry.path) { previous[path] = hash }
                }
                generation = (chainEntries.map(\.sequence).max() ?? 0) + 1
            } else if let items = try? fm.contentsOfDirectory(atPath: ascPath), items.contains(where: { $0.hasSuffix(".mhl") }) {
                throw ASCMHLError.unreadableHistory(tr("manca {0}", chainFileName))
            }
        }

        // 2. attraversamento in post-ordine (come lo strumento ufficiale)
        var entries: [Entry] = []
        var rehashed = 0
        var fileCount = 0
        let hashStamp = Date()

        func walk(abs: String, rel: String) throws -> (content: String, structure: String) {
            if isCancelled() { throw ASCMHLError.cancelled }
            var names = ((try? fm.contentsOfDirectory(atPath: abs)) ?? []).filter { !ignoredNames.contains($0) && !$0.hasSuffix(OffloadEngine.partialSuffix) }
            names.sort { Array($0.unicodeScalars.map(\.value)).lexicographicallyPrecedes(Array($1.unicodeScalars.map(\.value))) }

            var kinds: [String: DiskIO.StatInfo] = [:]
            for name in names {
                guard let info = try? DiskIO.lstatInfo(path: abs + "/" + name), !info.isSymlink, info.isDirectory || info.isRegular else { continue }
                kinds[name] = info
            }
            var childDirs: [String: (content: String, structure: String)] = [:]
            for name in names where kinds[name]?.isDirectory == true {
                childDirs[name] = try walk(abs: abs + "/" + name, rel: rel.isEmpty ? name : rel + "/" + name)
            }

            var contentHashes: [String] = []
            var structureHashes: [String] = []
            for name in names {
                guard let info = kinds[name] else { continue }
                if info.isDirectory, let child = childDirs[name] {
                    contentHashes.append(child.content)
                    structureHashes.append(hash(of: Data(name.utf8) + bytes(fromHex: child.structure)))
                } else if info.isRegular {
                    if isCancelled() { throw ASCMHLError.cancelled }
                    let path = rel.isEmpty ? name : rel + "/" + name
                    try validateXML(path)
                    var fileHash = knownHashes[path]
                    var computedAt: Date?
                    if fileHash == nil {
                        fileHash = try FileVerifier.hash(path: abs + "/" + name, uncached: false, bufferSize: 8 * 1024 * 1024).0
                        computedAt = Date()
                        rehashed += 1
                    }
                    guard let hex = fileHash?.lowercased() else { continue }
                    let action: String
                    if let old = previous[path] { action = old == hex ? "verified" : "failed" } else { action = "original" }
                    entries.append(.file(path: path, size: info.size, modified: info.times.modification, hash: hex, action: action, hashDate: computedAt))
                    fileCount += 1
                    contentHashes.append(hex)
                    structureHashes.append(hash(of: Data(name.utf8) + bytes(fromHex: hex)))
                }
            }
            let content = hashOfList(contentHashes)
            let structure = hashOfList(structureHashes)
            if !rel.isEmpty {
                let modified = (try? DiskIO.lstatInfo(path: abs).times.modification) ?? now
                try validateXML(rel)
                entries.append(.directory(path: rel, modified: modified, content: content, structure: structure, hashDate: hashStamp))
            }
            return (content, structure)
        }
        let rootHashes = try walk(abs: rootPath, rel: "")

        // 3. file .mhl
        let creation = now
        let fileName = String(format: "%04d_%@_%@Z.mhl", generation, root.standardizedFileURL.lastPathComponent, filenameStamp(creation))
        try validateXML(fileName)
        let xml = render(creation: creation, options: options, rootHashes: rootHashes, hashStamp: hashStamp, entries: entries)
        let mhlData = Data(xml.utf8)

        try fm.createDirectory(atPath: ascPath, withIntermediateDirectories: true)
        let mhlPath = ascPath + "/" + fileName
        guard !fm.fileExists(atPath: mhlPath) else { throw ASCMHLError.unreadableHistory(tr("{0} esiste già", fileName)) }
        guard fm.createFile(atPath: mhlPath, contents: mhlData) else {
            throw DiskIOError(code: errno, operation: tr("Creazione file"), path: mhlPath)
        }
        syncFile(mhlPath)

        // 4. catena (con l'identificatore C4 del file appena scritto)
        chainEntries.append((generation, fileName, C4ID.string(for: mhlData)))
        let chain = renderChain(chainEntries.sorted { $0.sequence < $1.sequence })
        let chainPath = ascPath + "/" + chainFileName
        let temp = ascPath + "/." + chainFileName + ".tmp"
        try? fm.removeItem(atPath: temp)
        guard fm.createFile(atPath: temp, contents: Data(chain.utf8)) else {
            throw DiskIOError(code: errno, operation: tr("Creazione file"), path: temp)
        }
        syncFile(temp)
        // rename(2) sostituisce la catena in modo atomico
        guard rename(temp, chainPath) == 0 else { throw DiskIOError(code: errno, operation: tr("Rinomina"), path: chainPath) }

        return ASCMHLWriteResult(folder: URL(fileURLWithPath: ascPath, isDirectory: true), file: URL(fileURLWithPath: mhlPath), generation: generation,
                                 fileCount: fileCount, rehashedCount: rehashed, rootContentHash: rootHashes.content, rootStructureHash: rootHashes.structure)
    }

    // MARK: Hash delle cartelle (stesso algoritmo dello strumento ufficiale)

    private static func hash(of data: Data) -> String {
        let hasher = XXH64Hasher()
        hasher.update(data)
        return hasher.hexDigest()
    }

    /// Hash dell'elenco di hash: ordinati come stringhe, concatenati come byte; elenco vuoto = hash dei zero byte.
    static func hashOfList(_ list: [String]) -> String {
        let hasher = XXH64Hasher()
        for h in list.sorted() { hasher.update(bytes(fromHex: h)) }
        return hasher.hexDigest()
    }

    private static func bytes(fromHex hex: String) -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
            data.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return data
    }

    // MARK: XML

    private enum Entry {
        case file(path: String, size: Int64, modified: Date, hash: String, action: String, hashDate: Date?)
        case directory(path: String, modified: Date, content: String, structure: String, hashDate: Date)
    }

    private static func render(creation: Date, options: ASCMHLOptions, rootHashes: (content: String, structure: String), hashStamp: Date, entries: [Entry]) -> String {
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<hashlist version=\"2.0\" xmlns=\"urn:ASC:MHL:v2.0\">\n"
        out += "  <creatorinfo>\n    <creationdate>\(iso(creation))</creationdate>\n    <hostname>\(escape(hostName()))</hostname>\n"
        out += "    <tool version=\"\(escape(AppInfo.version))\">\(escape(AppInfo.name))</tool>\n"
        if let author = options.author { out += "    <author>\(escape(author))</author>\n" }
        if let comment = options.comment, !comment.isEmpty { out += "    <comment>\(escape(comment))</comment>\n" }
        out += "  </creatorinfo>\n  <processinfo>\n    <process>transfer</process>\n    <roothash>\n"
        out += "      <content>\n        <xxh64 hashdate=\"\(iso(hashStamp, micro: true))\">\(rootHashes.content)</xxh64>\n      </content>\n"
        out += "      <structure>\n        <xxh64 hashdate=\"\(iso(hashStamp, micro: true))\">\(rootHashes.structure)</xxh64>\n      </structure>\n    </roothash>\n"
        out += "    <ignore>\n      <pattern>.DS_Store</pattern>\n      <pattern>ascmhl</pattern>\n      <pattern>ascmhl/</pattern>\n    </ignore>\n  </processinfo>\n"
        if !entries.isEmpty {
            out += "  <hashes>\n"
            for entry in entries {
                switch entry {
                case let .file(path, size, modified, hash, action, hashDate):
                    out += "    <hash>\n      <path size=\"\(size)\" lastmodificationdate=\"\(iso(modified))\">\(escape(path))</path>\n"
                    let date = hashDate.map { " hashdate=\"\(iso($0, micro: true))\"" } ?? ""
                    out += "      <xxh64 action=\"\(action)\"\(date)>\(hash)</xxh64>\n    </hash>\n"
                case let .directory(path, modified, content, structure, hashDate):
                    let date = " hashdate=\"\(iso(hashDate, micro: true))\""
                    out += "    <directoryhash>\n      <path lastmodificationdate=\"\(iso(modified))\">\(escape(path))</path>\n"
                    out += "      <content>\n        <xxh64\(date)>\(content)</xxh64>\n      </content>\n"
                    out += "      <structure>\n        <xxh64\(date)>\(structure)</xxh64>\n      </structure>\n    </directoryhash>\n"
                }
            }
            out += "  </hashes>\n"
        }
        return out + "</hashlist>\n"
    }

    private static func renderChain(_ entries: [(sequence: Int, path: String, c4: String)]) -> String {
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<ascmhldirectory xmlns=\"urn:ASC:MHL:DIRECTORY:v2.0\">\n"
        for e in entries {
            out += "  <hashlist sequencenr=\"\(e.sequence)\">\n    <path>\(escape(e.path))</path>\n    <c4>\(e.c4)</c4>\n  </hashlist>\n"
        }
        return out + "</ascmhldirectory>\n"
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Un percorso con caratteri di controllo non è rappresentabile in XML 1.0: meglio non creare il MHL che scriverne uno non valido.
    private static func validateXML(_ text: String) throws {
        for u in text.unicodeScalars where (u.value < 0x20 && u != "\t" && u != "\n" && u != "\r") || u.value == 0xFFFE || u.value == 0xFFFF || (0xD800...0xDFFF).contains(u.value) {
            throw ASCMHLError.invalidPath(text)
        }
    }

    private static func iso(_ date: Date, micro: Bool = false) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = micro ? "yyyy-MM-dd'T'HH:mm:ss.SSSSSSxxx" : "yyyy-MM-dd'T'HH:mm:ssxxx"
        return f.string(from: date)
    }

    private static func filenameStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f.string(from: date)
    }

    private static func hostName() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count - 1) == 0 else { return "unknown" }
        let name = String(cString: buffer)
        return name.isEmpty ? "unknown" : name
    }

    private static func syncFile(_ path: String) {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return }
        _ = fsync(fd)
        close(fd)
    }

    // MARK: Lettura della cronologia esistente

    private static func readChain(path: String) throws -> [(sequence: Int, path: String, c4: String)] {
        guard let data = FileManager.default.contents(atPath: path) else { throw ASCMHLError.unreadableHistory(chainFileName) }
        let parser = XMLParser(data: data)
        let delegate = ChainDelegate()
        parser.delegate = delegate
        guard parser.parse(), !delegate.entries.isEmpty else { throw ASCMHLError.unreadableHistory(chainFileName) }
        return delegate.entries
    }

    private final class ChainDelegate: NSObject, XMLParserDelegate {
        var entries: [(sequence: Int, path: String, c4: String)] = []
        private var sequence: Int?
        private var path = "", c4 = "", text = "", current = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            current = name
            text = ""
            if name == "hashlist" { sequence = attributes["sequencenr"].flatMap(Int.init); path = ""; c4 = "" }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if name == "path" { path = value } else if name == "c4" { c4 = value }
            else if name == "hashlist", let sequence, !path.isEmpty { entries.append((sequence, path, c4)) }
            text = ""
        }
    }

    /// Percorso → XXH64 registrato in una generazione precedente.
    private static func readHashes(path: String) throws -> [String: String] {
        guard let data = FileManager.default.contents(atPath: path) else { throw ASCMHLError.unreadableHistory((path as NSString).lastPathComponent) }
        let parser = XMLParser(data: data)
        let delegate = HashesDelegate()
        parser.delegate = delegate
        guard parser.parse() else { throw ASCMHLError.unreadableHistory((path as NSString).lastPathComponent) }
        return delegate.hashes
    }

    private final class HashesDelegate: NSObject, XMLParserDelegate {
        var hashes: [String: String] = [:]
        private var stack: [String] = []
        private var text = ""
        private var path: String?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            stack.append(name)
            text = ""
            if name == "hash" { path = nil }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // solo i file («hash»), non le cartelle («directoryhash»)
            if stack.suffix(2) == ["hash", "path"] { path = value }
            else if stack.suffix(2) == ["hash", "xxh64"], let path { hashes[path] = value.lowercased() }
            text = ""
            _ = stack.popLast()
        }
    }
}
