import Foundation

/// Esporta i metadata dei clip in JSON, CSV e ALE (Avid Log Exchange). Ogni riga è legata all'XXH64 del file calcolato in copia (se c'è).
/// Un dato non letto resta vuoto/assente: mai «N/D» né valori inventati.
public enum MetadataExporter {
    public enum Format: String, CaseIterable, Identifiable {
        case json, csv, ale
        public var id: String { rawValue }
        public var fileExtension: String { rawValue }
    }

    /// Colonne fisse (prima i dati del file e dell'offload, poi i campi metadata nell'ordine di `ClipMetadata.columnKeys`).
    static let fileColumns: [(key: String, title: String)] = [
        ("name", "Name"), ("path", "Path"), ("bin", "Bin"), ("day", "Day"), ("size", "Size (bytes)"), ("xxh64", "XXH64"), ("status", "Status"),
    ]

    public static func data(for clips: [ClipRecord], format: Format, includeRaw: Bool = true, now: Date = Date()) throws -> Data {
        switch format {
        case .json: return try json(clips, includeRaw: includeRaw, now: now)
        case .csv: return Data(csv(clips, includeRaw: includeRaw).utf8)
        case .ale: return Data(ale(clips).utf8)
        }
    }

    // MARK: Comuni

    static func fields(of clip: ClipRecord) -> (values: [String: String], raw: [String: String]) {
        var values: [String: String] = [:], raw: [String: String] = [:]
        for (k, v) in clip.metadata {
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            if k.hasPrefix(ClipMetadata.rawPrefix) { raw[String(k.dropFirst(ClipMetadata.rawPrefix.count))] = t } else { values[k] = t }
        }
        return (values, raw)
    }

    static func base(_ clip: ClipRecord) -> [String: String] {
        var out: [String: String] = ["name": clip.name, "path": clip.relativePath, "bin": clip.binName, "day": clip.dayName,
                                      "size": String(clip.size), "status": clip.status]
        if let h = clip.sourceHash { out["xxh64"] = h }
        return out
    }

    /// Chiavi dei campi presenti in almeno un clip: prima quelle note (ordine fisso), poi le altre in ordine alfabetico.
    static func fieldKeys(_ clips: [ClipRecord]) -> [String] {
        let present = Set(clips.flatMap { fields(of: $0).values.keys })
        let known = ClipMetadata.columnKeys.map(\.key)
        return known.filter { present.contains($0) } + present.subtracting(known).sorted()
    }

    // MARK: JSON

    static func json(_ clips: [ClipRecord], includeRaw: Bool, now: Date) throws -> Data {
        let iso = ISO8601DateFormatter()
        var list: [[String: Any]] = []
        for clip in clips {
            let f = fields(of: clip)
            var item: [String: Any] = base(clip)
            item["size"] = clip.size
            item["destinations"] = clip.destinationStatuses
            item["metadata"] = f.values
            if includeRaw && !f.raw.isEmpty { item["rawFields"] = f.raw }
            list.append(item)
        }
        let root: [String: Any] = ["generator": "\(AppInfo.name) \(AppInfo.version)", "exportedAt": iso.string(from: now), "clipCount": clips.count, "clips": list]
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: CSV

    static func csv(_ clips: [ClipRecord], includeRaw: Bool) -> String {
        let keys = fieldKeys(clips)
        let rawKeys = includeRaw ? Array(Set(clips.flatMap { fields(of: $0).raw.keys })).sorted() : []
        let labels = Dictionary(uniqueKeysWithValues: ClipMetadata.columnKeys.map { ($0.key, $0.label) })
        var header = fileColumns.map(\.title) + keys.map { labels[$0] ?? $0 } + rawKeys.map { "raw: \($0)" }
        header = header.map(escapeCSV)
        var lines = [header.joined(separator: ",")]
        for clip in clips {
            let b = base(clip), f = fields(of: clip)
            let row = fileColumns.map { b[$0.key] ?? "" } + keys.map { f.values[$0] ?? "" } + rawKeys.map { f.raw[$0] ?? "" }
            lines.append(row.map(escapeCSV).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    static func escapeCSV(_ s: String) -> String {
        guard s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: ALE

    /// Colonne ALE: (titolo, chiave dei metadata). Start/End/Tape/Tracks hanno un trattamento a parte.
    static let aleColumns: [(title: String, key: String)] = [
        ("Camera Type", "camera"), ("Camera Serial", "cameraSerial"), ("Firmware", "firmware"), ("Codec", "codec"), ("Resolution", "resolution"),
        ("Lens", "lens"), ("Focal Length", "focalLength"), ("Aperture", "aperture"), ("T-Stop", "tStop"), ("Focus Distance", "focusDistance"),
        ("ISO", "iso"), ("White Balance", "whiteBalance"), ("Shutter", "shutter"), ("Shutter Angle", "shutterAngle"),
        ("Color Space", "colorSpace"), ("Gamma", "gamma"), ("Scene", "scene"), ("Take", "take"), ("Date Shot", "createDate"),
    ]

    static func ale(_ clips: [ClipRecord]) -> String {
        // FPS del file: il più frequente tra i clip che lo dichiarano (l'ALE ne ha uno solo)
        var rateCount: [Double: Int] = [:]
        for c in clips { if let r = c.metadata["frameRate"].flatMap(Double.init), r > 0 { rateCount[r, default: 0] += 1 } }
        let fps = rateCount.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key
        var out = "Heading\nFIELD_DELIM\tTABS\nVIDEO_FORMAT\t1080\nAUDIO_FORMAT\t48khz\n"
        if let fps { out += "FPS\t\(TagBag.format(fps))\n" }
        out += "\nColumn\n"
        let used = aleColumns.filter { col in clips.contains { !(($0.metadata[col.key] ?? "").isEmpty) } }
        let columns = ["Name", "Tracks", "Start", "End", "Tape", "Source File", "XXH64"] + used.map(\.title)
        out += columns.joined(separator: "\t") + "\n\nData\n"
        for clip in clips {
            let m = clip.metadata
            let rate = m["frameRate"].flatMap(Double.init)
            let start = (m["timecode"] ?? "")
            var end = ""
            if !start.isEmpty, let rate, rate == rate.rounded(), rate > 0, let d = m["durationSeconds"].flatMap(Double.init) {
                end = addFrames(start, frames: Int((d * rate).rounded()), timebase: Int(rate)) ?? ""
            }
            let tracks = clip.isAudio ? "A" : (m["audioChannels"] != nil ? "VA" : "V")
            var row = [clip.name, tracks, start, end, m["reel"] ?? "", clip.relativePath, clip.sourceHash ?? ""]
            row += used.map { m[$0.key] ?? "" }
            out += row.map(cleanALE).joined(separator: "\t") + "\n"
        }
        return out
    }

    static func cleanALE(_ s: String) -> String {
        s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    /// HH:MM:SS:FF + frames (non drop-frame). nil se `start` non è un timecode intero valido.
    static func addFrames(_ start: String, frames: Int, timebase: Int) -> String? {
        let p = start.split(separator: ":").compactMap { Int($0) }
        guard p.count == 4, timebase > 0, p[3] < timebase else { return nil }
        let total = ((p[0] * 3600 + p[1] * 60 + p[2]) * timebase + p[3] + frames) % (24 * 3600 * timebase)
        return String(format: "%02d:%02d:%02d:%02d", total / (3600 * timebase), (total / (60 * timebase)) % 60, (total / timebase) % 60, total % timebase)
    }
}
