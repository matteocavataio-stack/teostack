import Foundation

/// Accesso ai tag di ExifTool (`-json -G1 -n`): chiavi «Gruppo:Nome»; una chiave senza gruppo cerca il nome in qualsiasi gruppo (in ordine alfabetico, per risultati ripetibili).
struct TagBag {
    let tags: [String: Any]

    private func value(_ key: String) -> Any? {
        if let v = tags[key] { return v }
        if !key.contains(":") {
            for k in tags.keys.sorted() where k.hasSuffix(":" + key) { return tags[k] }
        }
        return nil
    }

    func string(_ keys: String...) -> String? { string(keys) }

    func string(_ keys: [String]) -> String? {
        for key in keys {
            switch value(key) {
            case let s as String:
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            case let n as NSNumber:
                return Self.format(n.doubleValue)
            default: continue
            }
        }
        return nil
    }

    func double(_ keys: String...) -> Double? {
        for key in keys {
            switch value(key) {
            case let n as NSNumber: return n.doubleValue
            case let s as String: if let d = Double(s.trimmingCharacters(in: .whitespaces)) { return d }
            default: continue
            }
        }
        return nil
    }

    func int(_ keys: String...) -> Int? {
        for key in keys {
            if let d = double(key), d.isFinite, abs(d) < 1e15 { return Int(d.rounded()) }
        }
        return nil
    }

    var all: [String: Any] { tags }

    /// 24.0 → «24», 23.976 → «23.976».
    static func format(_ d: Double, decimals: Int = 3) -> String {
        if d == d.rounded(), abs(d) < 1e15 { return String(Int(d)) }
        return ClipMetadata.trimmed(d, decimals: decimals)
    }

    /// «2026:10:28 15:30:05» → «2026-10-28 15:30:05». Un valore incompleto (es. senza secondi) resta incompleto: nessuna cifra viene aggiunta.
    static func date(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespaces), s.count >= 10 else { return nil }
        s = s.replacingOccurrences(of: "T", with: " ")
        let parts = s.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count >= 1 else { return nil }
        let d = parts[0].replacingOccurrences(of: ":", with: "-")
        // «0000-00-00»: data non impostata dalla camera
        guard d.count == 10, d.first?.isNumber == true, !d.hasPrefix("0000") else { return nil }
        guard parts.count == 2 else { return d }
        var t = parts[1]
        while t.hasSuffix(":") { t.removeLast() }
        if let dot = t.firstIndex(of: ".") { t = String(t[t.startIndex ..< dot]) }
        // taglia il fuso orario («+01:00», «Z») per non mostrare un valore che il file non dichiara in modo omogeneo
        if let tz = t.firstIndex(where: { $0 == "+" || $0 == "Z" || ($0 == "-" && t.distance(from: t.startIndex, to: $0 == "-" ? t.firstIndex(of: "-")! : t.startIndex) > 2) }) {
            t = String(t[t.startIndex ..< tz])
        }
        return t.isEmpty ? d : "\(d) \(t)"
    }
}
