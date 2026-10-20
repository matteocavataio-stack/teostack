import Foundation

/// Parser per i clip ARRI a partire dai tag di ExifTool (`-json -G1 -n`).
///
/// Legge SOLO ciò che ExifTool espone davvero nei file MXF ARRI (verificato su un clip ALEXA 35):
/// camera, firmware, risoluzione, frame rate del file, durata, timecode iniziale, data di creazione.
/// ISO, bilanciamento del bianco, lente, filtro ND, look e sensor FPS NON sono letti da ExifTool: restano assenti (→ N/D)
/// finché non si collega ARRI Meta Extract.
public enum ARRIMetadataParser {
    public static func canParse(_ tags: [String: Any]) -> Bool {
        (tags["MXF:ApplicationSupplierName"] as? String)?.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("ARRI") == .orderedSame
    }

    public static func parse(_ tags: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]

        if let v = string(tags["MXF:ApplicationName"]) { out["camera"] = v }
        if let v = string(tags["MXF:ApplicationSupplierName"]) { out["manufacturer"] = v }
        if let v = string(tags["MXF:ApplicationVersionString"]) { out["firmware"] = v }

        if let size = string(tags["Composite:ImageSize"]) {
            let parts = size.split(whereSeparator: { $0 == " " || $0 == "x" }).map(String.init)
            if parts.count == 2, Int(parts[0]) != nil, Int(parts[1]) != nil { out["resolution"] = "\(parts[0])x\(parts[1])" }
        }
        if out["resolution"] == nil,
           let wKey = tags.keys.sorted().first(where: { $0.hasSuffix(":ImageWidth") && $0.hasPrefix("Track") }),
           let hKey = tags.keys.sorted().first(where: { $0.hasSuffix(":ImageHeight") && $0.hasPrefix("Track") }),
           let w = number(tags[wKey]), let h = number(tags[hKey]) {
            out["resolution"] = "\(Int(w))x\(Int(h))"
        }

        let rate = number(tags["MXF:SampleRate"])
        if let rate { out["frameRate"] = formatRate(rate) }
        if let d = number(tags["MXF:Duration"]) { out["durationSeconds"] = trimmed(d, decimals: 3) }

        if let tc = startTimecode(tags, fallbackRate: rate) { out["timecode"] = tc }
        if let created = string(tags["MXF:CreateDate"]), let formatted = formatDate(created) { out["createDate"] = formatted }
        return out
    }

    // MARK: Timecode

    /// ExifTool restituisce lo start timecode come secondi (frame / edit rate). Si ricostruisce HH:MM:SS:FF.
    /// Con timecode drop-frame non si calcola nulla (assente → N/D) per non mostrare un valore potenzialmente sbagliato.
    static func startTimecode(_ tags: [String: Any], fallbackRate: Double?) -> String? {
        guard let key = tags.keys.sorted().first(where: { $0.hasSuffix(":StartTimecode") }),
              let seconds = number(tags[key]) else { return nil }
        let prefix = String(key.dropLast(":StartTimecode".count))
        if let drop = tags["\(prefix):DropFrame"] as? Bool, drop { return nil }
        guard let timebase = number(tags["\(prefix):RoundedTimecodeTimebase"]).map(Int.init), timebase > 0 else { return nil }
        let editRate = number(tags["\(prefix):EditRate"]) ?? fallbackRate ?? Double(timebase)
        return timecode(seconds: seconds, editRate: editRate, timebase: timebase)
    }

    public static func timecode(seconds: Double, editRate: Double, timebase: Int) -> String {
        let frames = Int((seconds * editRate).rounded())
        let perHour = timebase * 3600, perMinute = timebase * 60
        let h = frames / perHour
        let m = (frames % perHour) / perMinute
        let s = (frames % perMinute) / timebase
        let f = frames % timebase
        return String(format: "%02d:%02d:%02d:%02d", h, m, s, f)
    }

    // MARK: Utilità

    private static func string(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func trimmed(_ v: Double, decimals: Int) -> String {
        var s = String(format: "%.\(decimals)f", v)
        while s.contains(".") && (s.hasSuffix("0") || s.hasSuffix(".")) { s.removeLast() }
        return s
    }

    private static func formatRate(_ v: Double) -> String { trimmed(v, decimals: 3) }

    /// "2025:10:20 13:23:07.000" → "2025-10-20 13:23:07" (nessun fuso orario nel file: non ne viene inventato uno).
    private static func formatDate(_ raw: String) -> String? {
        let parts = raw.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let date = parts[0].replacingOccurrences(of: ":", with: "-")
        let time = String(parts[1].split(separator: ".").first ?? "")
        guard date.count == 10, time.count == 8 else { return nil }
        return "\(date) \(time)"
    }
}
