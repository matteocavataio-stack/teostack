import Foundation

/// I cinque report, come nel formato di riferimento (template «Classic»).
public enum ReportKind: String, CaseIterable, Identifiable {
    case shootingDay, clips, volume, thumbnail, contactPrint

    public var id: String { rawValue }

    /// Titolo del report: compare in alto a sinistra in ogni pagina.
    public var title: String {
        switch self {
        case .shootingDay: return "Shooting Day Report"
        case .clips: return "Clips Report"
        case .volume: return "Volume Report"
        case .thumbnail: return "Thumbnail Report"
        case .contactPrint: return "Contact Print Report"
        }
    }

    /// Nome del report nella lingua dell'app (per le caselle e i messaggi; nel PDF il titolo resta in inglese).
    public var uiTitle: String {
        switch self {
        case .shootingDay: return tr("Report giornata di riprese (Shooting Day)")
        case .clips: return tr("Report clip (Clips)")
        case .volume: return tr("Report volumi (Volume)")
        case .thumbnail: return tr("Report miniature (Thumbnail)")
        case .contactPrint: return tr("Foglio provini (Contact Print)")
        }
    }

    /// Parte iniziale del nome del file: «Clips_Report-<bin>-2026-10-20-1455.pdf».
    public var filePrefix: String { title.replacingOccurrences(of: " ", with: "_") }

    public func fileName(scopeName: String, date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmm"
        let safe = scopeName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "\(filePrefix)-\(safe)-\(f.string(from: date)).pdf"
    }
}

public struct ReportOptions {
    public var projectName: String
    public var operatorName: String
    public var notes: String
    public var generatedAt: Date
    /// Colonne scelte dall'utente (id di `ClipColumns`) per i report Clips e Thumbnail; nil = tutte le colonne del formato di riferimento.
    public var columnIDs: [String]?

    public init(projectName: String, operatorName: String = "", notes: String = "", generatedAt: Date = Date(), columnIDs: [String]? = nil) {
        self.columnIDs = columnIDs
        self.projectName = projectName
        self.operatorName = operatorName
        self.notes = notes
        self.generatedAt = generatedAt
    }
}

/// Un file dell'offload: clip video, clip audio o altro file (ALE, BIN, XML…).
struct ReportItem {
    enum Kind { case video, audio, other }

    let clip: ClipRecord
    let kind: Kind
    let offload: OffloadRecord?
    let thumbnail: URL?

    var fileName: String { clip.name }
    var fileExtension: String { (clip.relativePath as NSString).pathExtension.lowercased() }
    /// Le clip si chiamano come il file senza estensione; gli altri file col nome completo.
    var name: String { kind == .other ? clip.name : (clip.name as NSString).deletingPathExtension }
    var isClip: Bool { kind != .other }

    func meta(_ key: String) -> String? {
        let v = clip.metadata[key]?.trimmingCharacters(in: .whitespaces)
        return (v?.isEmpty ?? true) ? nil : v
    }

    var durationSeconds: Double? { isClip ? meta("durationSeconds").flatMap(Double.init) : nil }
    var fps: Double? { meta("frameRate").flatMap(Double.init) }
    /// Frame = durata × FPS del file (entrambi letti dal clip).
    var frames: Int? {
        guard let d = durationSeconds, let f = fps else { return nil }
        return Int((d * f).rounded())
    }

    var sourceVolume: String? { offload.map { ReportFormatting.volumeName($0.sourcePath) } }
    var sourcePath: String? { offload.map { ($0.sourcePath as NSString).appendingPathComponent(clip.relativePath) } }
    var destinationPaths: [String] { (offload?.destinations ?? []).map { ($0 as NSString).appendingPathComponent(clip.relativePath) } }
    var volumes: [String] {
        var out: [String] = []
        if let s = sourceVolume { out.append(s) }
        for d in offload?.destinations ?? [] { out.append(ReportFormatting.volumeName(d)) }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }
    var backups: Int { offload?.destinations.count ?? clip.destinationStatuses.count }
    var verifiedBackups: Int { clip.destinationStatuses.filter { $0 == "ok" }.count }
    var verificationState: String {
        if clip.destinationStatuses.contains("mismatch") || clip.destinationStatuses.contains("error") { return "failed" }
        if !clip.destinationStatuses.isEmpty && clip.destinationStatuses.allSatisfy({ $0 == "ok" }) { return "verified" }
        return "unverified"
    }
}

struct ReportContext {
    var kind: ReportKind
    var title: String                 // bin / giorno / progetto
    var projectName: String
    var offloadStarted: Date?
    var generatedAt: Date
    var operatorName: String
    var notes: String
    var items: [ReportItem]
    var offloads: [OffloadRecord]
    var columnIDs: [String]? = nil
    var scopeName: String { title }

    var videoClips: [ReportItem] { items.filter { $0.kind == .video } }
    var audioClips: [ReportItem] { items.filter { $0.kind == .audio } }
    var otherFiles: [ReportItem] { items.filter { $0.kind == .other } }
    var allClips: [ReportItem] { items.filter { $0.isClip } }

    /// Righe di «Production Info» (vuote se non ci sono dati).
    var productionInfo: [(String, String)] {
        func values(_ key: String) -> String? {
            var seen = Set<String>(), out: [String] = []
            for i in videoClips { if let v = i.meta(key), seen.insert(v).inserted { out.append(v) } }
            return out.isEmpty ? nil : out.joined(separator: "; ")
        }
        var rows: [(String, String)] = []
        for (label, key) in [("Production", "production"), ("Production Company", "productionCompany"), ("Director", "director"),
                             ("Cinematographer", "cinematographer"), ("Location", "location")] {
            if let v = values(key) { rows.append((label, v)) }
        }
        let op = operatorName.trimmingCharacters(in: .whitespaces)
        if !op.isEmpty { rows.append(("DIT", op)) }
        let n = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { rows.append(("Notes", n)) }
        return rows
    }
}

public enum ReportContextBuilder {
    public static func scopeName(store: ProjectStore, projectID: Int64, nodeID: Int64, projectName: String) throws -> String {
        let tree = try store.tree(projectID: projectID)
        guard let node = find(nodeID, in: tree) else { throw ProjectStoreError.notFound(tr("Elemento del progetto non trovato.")) }
        return node.kind == .library ? projectName : node.name
    }

    static func find(_ id: Int64, in node: TreeNode) -> TreeNode? {
        if node.id == id { return node }
        for c in node.children ?? [] { if let f = find(id, in: c) { return f } }
        return nil
    }

    static func build(kind: ReportKind, store: ProjectStore, projectID: Int64, nodeID: Int64,
                      options: ReportOptions, thumbnails: ThumbnailCache?) throws -> ReportContext {
        let title = try scopeName(store: store, projectID: projectID, nodeID: nodeID, projectName: options.projectName)
        let clips = try store.clips(underNode: nodeID, mediaOnly: false)
        let offloads = try store.offloads(underNode: nodeID)
        let byOffload = Dictionary(uniqueKeysWithValues: offloads.map { ($0.id, $0) })
        var items = clips.map { clip -> ReportItem in
            let kind: ReportItem.Kind = MediaClassifier.isMedia(relativePath: clip.relativePath) ? .video
                : (MediaClassifier.isAudio(relativePath: clip.relativePath) ? .audio : .other)
            let thumb = thumbnails.flatMap { $0.hasImage(clipID: clip.id) ? $0.imageURL(clipID: clip.id) : nil }
            return ReportItem(clip: clip, kind: kind, offload: byOffload[clip.offloadID], thumbnail: thumb)
        }
        items.sort { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
        return ReportContext(kind: kind, title: title, projectName: options.projectName,
                             offloadStarted: offloads.map(\.startedAt).min(), generatedAt: options.generatedAt,
                             operatorName: options.operatorName, notes: options.notes, items: items, offloads: offloads,
                             columnIDs: options.columnIDs)
    }
}

enum ReportFormatting {
    static func locale() -> Locale { Locale(identifier: "en_GB") }

    /// «06/06/2025, 10:36»
    static func dateTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "dd/MM/yyyy, HH:mm"
        return f.string(from: d)
    }

    /// «2025-10-20 13:23:07» (nessun fuso nel file) → «20/10/2025, 13:23»
    static func recordingDate(_ raw: String) -> String? {
        let parts = raw.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let d = parts[0].split(separator: "-"), t = parts[1].split(separator: ":")
        guard d.count == 3, t.count >= 2 else { return nil }
        return "\(d[2])/\(d[1])/\(d[0]), \(t[0]):\(t[1])"
    }

    /// «35 sec» · «2 min 5 sec» · «1 h 2 min 3 sec»
    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) sec" }
        if s < 3600 { return "\(s / 60) min \(s % 60) sec" }
        return "\(s / 3600) h \((s % 3600) / 60) min \(s % 60) sec"
    }

    static func volumeName(_ path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        if parts.count >= 2, parts[0] == "Volumes" { return parts[1] }
        return "Internal disk"
    }

    /// «13:23:05:17» → «13:23:05.17» (come i timecode del formato di riferimento)
    static func timecode(_ tc: String) -> String {
        var parts = tc.split(separator: ":").map(String.init)
        guard parts.count == 4 else { return tc }
        let frames = parts.removeLast()
        return parts.joined(separator: ":") + "." + frames
    }

    /// Timecode di fine = inizio + durata in frame (fine esclusiva, come nel riferimento: 328 frame da 00:45:08.02 → 00:45:21.05).
    static func timecodeEnd(start: String, frames: Int, fps: Double) -> String? {
        let parts = start.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 4, fps > 0, fps == fps.rounded() else { return nil }
        let base = Int(fps)
        let total = ((parts[0] * 3600 + parts[1] * 60 + parts[2]) * base + parts[3]) + frames
        let f = total % base, s = (total / base) % 60, m = (total / (base * 60)) % 60, h = total / (base * 3600)
        return String(format: "%02d:%02d:%02d.%02d", h, m, s, f)
    }

    /// Dimensione come nel riferimento: «20.77 GB», «4.02 KB», «0.00 KB».
    static func size(_ bytes: Int64) -> String {
        if bytes <= 0 { return "0.00 KB" }
        let units = ["KB", "MB", "GB", "TB"]
        var v = Double(bytes) / 1000
        var u = 0
        while v >= 1000 && u < units.count - 1 { v /= 1000; u += 1 }
        return String(format: "%.2f %@", v, units[u])
    }

    /// Byte invertiti: «xxHash64» del riferimento è la forma little-endian dell'XXH64 canonico (quella di xxhsum, «xxHash64BE»).
    static func littleEndian(hex: String) -> String {
        var out = ""
        var i = hex.endIndex
        while i > hex.startIndex {
            let start = hex.index(i, offsetBy: -2, limitedBy: hex.startIndex) ?? hex.startIndex
            out += hex[start..<i]
            i = start
        }
        return out
    }
}
