import Foundation

/// Colonna della tabella clip. Le colonne "metadata" leggono `ClipRecord.metadata[id]`; se manca mostrano "N/D".
public struct ClipColumn: Identifiable, Hashable {
    public let id: String
    public let title: String
    public let isMetadata: Bool
    public let width: Double
}

public enum ClipColumns {
    public static let notAvailable = "N/D"

    public static let all: [ClipColumn] = [
        ClipColumn(id: "name", title: "Nome", isMetadata: false, width: 220),
        ClipColumn(id: "day", title: "Giorno", isMetadata: false, width: 140),
        ClipColumn(id: "bin", title: "Bin", isMetadata: false, width: 130),
        ClipColumn(id: "size", title: "Dimensione", isMetadata: false, width: 100),
        ClipColumn(id: "hash", title: "XXH64", isMetadata: false, width: 150),
        ClipColumn(id: "status", title: "Stato", isMetadata: false, width: 90),
        ClipColumn(id: "offloadDate", title: "Offload", isMetadata: false, width: 130),
        ClipColumn(id: "path", title: "Percorso", isMetadata: false, width: 260),
        ClipColumn(id: "camera", title: "Camera", isMetadata: true, width: 110),
        ClipColumn(id: "codec", title: "Codec", isMetadata: true, width: 110),
        ClipColumn(id: "resolution", title: "Risoluzione", isMetadata: true, width: 110),
        ClipColumn(id: "sensorFPS", title: "Sensor FPS", isMetadata: true, width: 90),
        ClipColumn(id: "ndFilter", title: "ND Filter", isMetadata: true, width: 90),
        ClipColumn(id: "lookInfo", title: "Look Info", isMetadata: true, width: 140),
        ClipColumn(id: "lens", title: "Lente", isMetadata: true, width: 150),
        ClipColumn(id: "iso", title: "ISO", isMetadata: true, width: 70),
        ClipColumn(id: "whiteBalance", title: "WB", isMetadata: true, width: 80),
        ClipColumn(id: "timecode", title: "Timecode", isMetadata: true, width: 110),
    ]

    public static let defaultVisibleIDs: [String] = ["name", "day", "bin", "size", "hash", "status", "codec", "resolution", "timecode"]

    public static func column(id: String) -> ClipColumn? { all.first { $0.id == id } }

    public static func statusLabel(_ status: String) -> String {
        switch status {
        case "ok": return "OK"
        case "mismatch": return "MISMATCH"
        case "error": return "ERRORE"
        default: return "In attesa"
        }
    }

    /// Testo da mostrare. Mai valori inventati: metadata assenti o vuoti → "N/D".
    public static func value(_ column: ClipColumn, of clip: ClipRecord) -> String {
        switch column.id {
        case "name": return clip.name
        case "day": return clip.dayName
        case "bin": return clip.binName
        case "size": return Format.bytes(clip.size)
        case "hash": return clip.sourceHash ?? notAvailable
        case "status": return statusLabel(clip.status)
        case "offloadDate":
            let f = DateFormatter()
            f.locale = Locale(identifier: "it_IT")
            f.dateFormat = "dd/MM/yyyy HH:mm"
            return f.string(from: clip.offloadDate)
        case "path": return clip.relativePath
        default:
            let v = clip.metadata[column.id]?.trimmingCharacters(in: .whitespaces) ?? ""
            return v.isEmpty ? notAvailable : v
        }
    }

    /// Chiave di ordinamento: numerica per la dimensione, testuale per il resto.
    public static func sorted(_ clips: [ClipRecord], by column: ClipColumn, ascending: Bool) -> [ClipRecord] {
        let result: [ClipRecord]
        if column.id == "size" {
            result = clips.sorted { $0.size < $1.size }
        } else if column.id == "offloadDate" {
            result = clips.sorted { $0.offloadDate < $1.offloadDate }
        } else {
            result = clips.sorted { value(column, of: $0).localizedStandardCompare(value(column, of: $1)) == .orderedAscending }
        }
        return ascending ? result : result.reversed()
    }
}
