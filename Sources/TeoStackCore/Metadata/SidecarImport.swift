import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Una riga di un file di log (ALE, CSV, XML…) con i nomi delle colonne come nel file.
public struct SidecarRecord: Equatable {
    public var fields: [String: String]
    public init(fields: [String: String]) { self.fields = fields }
}

public enum SidecarFormat: String, CaseIterable {
    case ale, csv, xml

    public static func detect(url: URL) -> SidecarFormat? {
        switch url.pathExtension.lowercased() {
        case "ale": return .ale
        case "csv", "tsv", "txt": return .csv
        case "xml": return .xml
        default: return nil
        }
    }
}

public enum SidecarParseError: Error, CustomStringConvertible, Equatable {
    case unreadable(String)
    case empty
    public var description: String {
        switch self {
        case .unreadable(let m): return tr("File non leggibile: {0}", m)
        case .empty: return tr("Il file non contiene righe riconoscibili.")
        }
    }
}

/// Lettura di log esterni (ALE, CSV generico, XML a record ripetuti). Solo lettura del file scelto.
public enum SidecarParser {
    public static func parse(url: URL, format: SidecarFormat? = nil) throws -> [SidecarRecord] {
        guard let format = format ?? SidecarFormat.detect(url: url) else { throw SidecarParseError.unreadable(url.lastPathComponent) }
        guard let data = try? Data(contentsOf: url) else { throw SidecarParseError.unreadable(url.lastPathComponent) }
        let records: [SidecarRecord]
        switch format {
        case .xml: records = parseXML(data)
        case .ale: records = parseALE(decode(data))
        case .csv: records = parseCSV(decode(data))
        }
        guard !records.isEmpty else { throw SidecarParseError.empty }
        return records
    }

    static func decode(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let s = String(data: data, encoding: .utf16) { return s }
        var d = data
        if d.starts(with: [0xEF, 0xBB, 0xBF]) { d = d.dropFirst(3) }
        return String(data: d, encoding: .utf8) ?? String(decoding: d, as: UTF8.self).replacingOccurrences(of: "\u{FFFD}", with: "?")
    }

    // MARK: ALE

    public static func parseALE(_ text: String) -> [SidecarRecord] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var header: [String]?
        var inData = false
        var awaitingHeader = false
        var out: [SidecarRecord] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !inData {
                if trimmed == "Column" { awaitingHeader = true; continue }
                if awaitingHeader, !trimmed.isEmpty { header = line.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }; awaitingHeader = false; continue }
                if trimmed == "Data" { inData = true }
                continue
            }
            guard let header, !trimmed.isEmpty else { continue }
            let cells = line.components(separatedBy: "\t")
            var f: [String: String] = [:]
            for (i, name) in header.enumerated() where !name.isEmpty && i < cells.count {
                let v = cells[i].trimmingCharacters(in: .whitespaces)
                if !v.isEmpty { f[name] = v }
            }
            if !f.isEmpty { out.append(SidecarRecord(fields: f)) }
        }
        return out
    }

    // MARK: CSV

    public static func parseCSV(_ text: String) -> [SidecarRecord] {
        let rows = csvRows(text)
        guard let header = rows.first(where: { $0.contains { !$0.isEmpty } }) else { return [] }
        let names = header.map { $0.trimmingCharacters(in: .whitespaces) }
        var out: [SidecarRecord] = []
        var seenHeader = false
        for row in rows {
            if !seenHeader { if row == header { seenHeader = true }; continue }
            var f: [String: String] = [:]
            for (i, name) in names.enumerated() where !name.isEmpty && i < row.count {
                let v = row[i].trimmingCharacters(in: .whitespaces)
                if !v.isEmpty { f[name] = v }
            }
            if !f.isEmpty { out.append(SidecarRecord(fields: f)) }
        }
        return out
    }

    /// Righe di un CSV con virgolette (RFC 4180); il separatore (virgola, punto e virgola, tab) si riconosce dalla prima riga.
    static func csvRows(_ text: String) -> [[String]] {
        let chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        var firstLine = ""
        var inQ = false
        for c in chars {
            if c == "\"" { inQ.toggle() }
            if c == "\n" && !inQ { break }
            firstLine.append(c)
        }
        let delimiter: Character = [",", ";", "\t"].max { count(of: $0, in: firstLine) < count(of: $1, in: firstLine) } ?? ","
        var rows: [[String]] = []
        var row: [String] = []
        var cell = ""
        inQ = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQ {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { cell.append("\""); i += 1 } else { inQ = false }
                } else { cell.append(c) }
            } else if c == "\"" { inQ = true }
            else if c == delimiter { row.append(cell); cell = "" }
            else if c == "\n" { row.append(cell); cell = ""; rows.append(row); row = [] }
            else { cell.append(c) }
            i += 1
        }
        if !cell.isEmpty || !row.isEmpty { row.append(cell); rows.append(row) }
        return rows
    }

    private static func count(of c: Character, in s: String) -> Int { s.reduce(0) { $1 == c ? $0 + 1 : $0 } }

    // MARK: XML

    /// XML a record ripetuti: l'elemento che compare più volte (con figli o attributi) è un record; attributi e figli semplici sono i campi.
    public static func parseXML(_ data: Data) -> [SidecarRecord] {
        let parser = XMLParser(data: data)
        let delegate = TreeBuilder()
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.root else { return [] }
        var counts: [String: Int] = [:]
        func walk(_ n: Node) { counts[n.name, default: 0] += 1; n.children.forEach(walk) }
        walk(root)
        func candidate(_ n: Node) -> Bool { !n.attributes.isEmpty || n.children.contains { $0.children.isEmpty && !$0.text.isEmpty } }
        var best: (name: String, count: Int)?
        func pick(_ n: Node) {
            if n !== root, candidate(n), let c = counts[n.name], c >= 1, c > (best?.count ?? 0) || (best == nil) { best = (n.name, c) }
            n.children.forEach(pick)
        }
        pick(root)
        guard let record = best?.name else { return [] }
        var out: [SidecarRecord] = []
        func collect(_ n: Node) {
            if n.name == record {
                var f: [String: String] = [:]
                for (k, v) in n.attributes where !v.isEmpty { f[k] = v }
                func leaves(_ m: Node, _ prefix: String) {
                    for c in m.children {
                        if c.children.isEmpty {
                            if !c.text.isEmpty { f[prefix + c.name] = c.text }
                            for (k, v) in c.attributes where !v.isEmpty && c.text.isEmpty { f[prefix + c.name + "@" + k] = v }
                        } else { leaves(c, prefix + c.name + "/") }
                    }
                }
                leaves(n, "")
                if !f.isEmpty { out.append(SidecarRecord(fields: f)) }
                return
            }
            n.children.forEach(collect)
        }
        collect(root)
        return out
    }

    final class Node {
        let name: String
        var attributes: [String: String] = [:]
        var text = ""
        var children: [Node] = []
        init(name: String) { self.name = name }
    }

    private final class TreeBuilder: NSObject, XMLParserDelegate {
        var root: Node?
        private var stack: [Node] = []
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            let n = Node(name: name.split(separator: ":").last.map(String.init) ?? name)
            for (k, v) in attributes { n.attributes[k.split(separator: ":").last.map(String.init) ?? k] = v.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let parent = stack.last { parent.children.append(n) } else { root = n }
            stack.append(n)
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if let n = stack.popLast() { n.text = n.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }
}

/// Nome di colonna di un log → chiave dei metadata dell'app.
public enum SidecarFieldMap {
    static func normalize(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// Alias per chiave canonica (normalizzati). `name`, `start`, `date` servono all'abbinamento; gli altri finiscono nei metadata.
    static let aliases: [(canonical: String, names: [String])] = [
        ("name", ["name", "clip", "clipname", "filename", "file", "sourcefile", "sourcename", "clipid"]),
        ("reel", ["tape", "reel", "reelname", "roll", "magazine", "mag", "card", "cardname", "reelid"]),
        ("scene", ["scene", "sceneno", "scenenumber", "scn", "sc"]),
        ("take", ["take", "takeno", "takenumber", "tk"]),
        ("cameraIndex", ["camera", "cameraid", "cam", "cameraindex", "cameraname", "cameranumber"]),
        ("start", ["start", "tcin", "starttc", "tcstart", "starttimecode", "timecode", "tc", "tcstartfile", "sourcestart"]),
        ("date", ["date", "dateshot", "shootdate", "createdate", "creationdate", "datecreated", "shotdate"]),
        ("notes", ["notes", "note", "comment", "comments", "description", "remarks"]),
    ]

    /// Per ogni colonna: la chiave canonica se riconosciuta, altrimenti nil.
    static func canonical(_ column: String) -> String? {
        let n = normalize(column)
        return aliases.first { $0.names.contains(n) }?.canonical
    }
}

/// Esito dell'importazione di un log.
public struct SidecarImportReport: Equatable {
    public var records = 0
    public var matched = 0
    public var ambiguous: [String] = []
    public var unmatched: [String] = []
    public var fieldsWritten = 0
    /// Campi che avevano già un valore diverso e non sono stati toccati (senza «sovrascrivi»).
    public var fieldsKept = 0

    public var text: String {
        var parts = [tr("{0} righe, {1} abbinate a un clip, {2} campi scritti", records, matched, fieldsWritten)]
        if fieldsKept > 0 { parts.append(tr("{0} campi già presenti lasciati invariati", fieldsKept)) }
        if !ambiguous.isEmpty { parts.append(tr("{0} righe ambigue (più clip possibili) ignorate", ambiguous.count)) }
        if !unmatched.isEmpty { parts.append(tr("{0} righe senza clip corrispondente", unmatched.count)) }
        return parts.joined(separator: ", ")
    }
}

public enum SidecarImporter {
    /// Abbina le righe ai clip e scrive i campi nel database. I valori già presenti NON vengono mai sovrascritti, salvo `overwrite: true`.
    /// Abbinamento: (1) stesso nome del file (con o senza estensione); (2) stesso timecode iniziale E stessa data. Più candidati → riga ignorata.
    public static func apply(_ records: [SidecarRecord], to clips: [ClipRecord], store: ProjectStore, overwrite: Bool = false) throws -> SidecarImportReport {
        var report = SidecarImportReport()
        report.records = records.count
        for record in records {
            var canon: [String: String] = [:]
            var extras: [String: String] = [:]
            for (column, value) in record.fields {
                if let key = SidecarFieldMap.canonical(column) { if canon[key] == nil { canon[key] = value } }
                else { extras["\(ClipMetadata.rawPrefix)sidecar:\(column)"] = value }
            }
            let label = canon["name"] ?? canon["start"] ?? record.fields.values.first ?? "?"
            switch match(canon, clips) {
            case .none: report.unmatched.append(label); continue
            case .ambiguous: report.ambiguous.append(label); continue
            case .one(let clip):
                report.matched += 1
                var values: [String: String] = [:]
                for key in ["reel", "scene", "take", "cameraIndex", "notes"] { if let v = canon[key] { values[key] = v } }
                for (k, v) in extras { values[k] = v }
                var write: [String: String] = [:]
                for (k, v) in values {
                    let current = clip.metadata[k]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if current.isEmpty || overwrite { if current != v { write[k] = v } }
                    else if current != v { report.fieldsKept += 1 }
                }
                if !write.isEmpty {
                    try store.updateMetadata(clipID: clip.id, merging: write)
                    report.fieldsWritten += write.count
                }
            }
        }
        return report
    }

    enum MatchResult { case none, ambiguous, one(ClipRecord) }

    static func match(_ canon: [String: String], _ clips: [ClipRecord]) -> MatchResult {
        if let name = canon["name"] {
            let wanted = stem(name)
            let exactFull = clips.filter { $0.name.lowercased() == (name as NSString).lastPathComponent.lowercased() }
            if exactFull.count == 1 { return .one(exactFull[0]) }
            if exactFull.count > 1 { return .ambiguous }
            let byStem = clips.filter { stem($0.name) == wanted }
            if byStem.count == 1 { return .one(byStem[0]) }
            if byStem.count > 1 { return .ambiguous }
        }
        if let start = canon["start"], let date = canon["date"].flatMap(day) {
            let found = clips.filter { c in
                guard let tc = c.metadata["timecode"], tc == start, let created = c.metadata["createDate"].flatMap(day) else { return false }
                return created == date
            }
            if found.count == 1 { return .one(found[0]) }
            if found.count > 1 { return .ambiguous }
        }
        return .none
    }

    static func stem(_ name: String) -> String { ((name as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased() }

    /// «2026-10-28 15:30», «2026:10:28», «28/10/2026», «2026-10-28T…» → «2026-10-28».
    static func day(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let head = String(s.prefix(10))
        if head.range(of: #"^\d{4}[-:/.]\d{2}[-:/.]\d{2}$"#, options: .regularExpression) != nil {
            return head.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        }
        if head.range(of: #"^\d{2}[-/.]\d{2}[-/.]\d{4}$"#, options: .regularExpression) != nil {
            let p = head.split(whereSeparator: { "-/.".contains($0) }).map(String.init)
            return "\(p[2])-\(p[1])-\(p[0])"      // giorno/mese/anno (formato europeo)
        }
        return nil
    }
}
