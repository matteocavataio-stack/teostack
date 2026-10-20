import Foundation

public struct MetadataSummary: Equatable {
    public var read = 0                   // clip con almeno un metadata letto
    public var unsupported = 0            // formato non riconosciuto da nessun parser: nessun valore scritto
    public var missingFile = 0            // file di destinazione non raggiungibile (disco scollegato?)
    public var failed: [String] = []      // errori di lettura "clip: messaggio"

    public var text: String {
        var parts = ["\(read) clip letti"]
        if unsupported > 0 { parts.append("\(unsupported) formato non supportato (N/D)") }
        if missingFile > 0 { parts.append("\(missingFile) file non raggiungibili") }
        if !failed.isEmpty { parts.append("\(failed.count) errori") }
        return parts.joined(separator: ", ")
    }
}

/// Legge i metadata dei clip e li salva nel database.
/// Si legge la COPIA verificata sulla destinazione (mai la scheda sorgente) e solo in lettura.
public enum MetadataImporter {
    /// Famiglie di camera supportate (un parser per famiglia). Ritorna nil se nessuna riconosce i tag.
    static func parse(_ tags: [String: Any]) -> [String: String]? {
        if ARRIMetadataParser.canParse(tags) { return ARRIMetadataParser.parse(tags) }
        return nil
    }

    public static func importMetadata(for clips: [ClipRecord], store: ProjectStore, runner: ExifToolRunner,
                                      progress: ((Int, Int) -> Void)? = nil) throws -> MetadataSummary {
        var summary = MetadataSummary()
        var rootsCache: [Int64: [String]] = [:]
        for (index, clip) in clips.enumerated() {
            progress?(index, clips.count)
            guard clip.isMedia, clip.status == "ok" else { continue }
            let roots = try rootsCache[clip.offloadID] ?? { let r = try store.destinationRoots(offloadID: clip.offloadID); rootsCache[clip.offloadID] = r; return r }()
            // prima copia verificata OK che esiste ancora su disco
            var file: String?
            for (d, root) in roots.enumerated() where d < clip.destinationStatuses.count && clip.destinationStatuses[d] == "ok" {
                let candidate = (root as NSString).appendingPathComponent(clip.relativePath)
                if FileManager.default.fileExists(atPath: candidate) { file = candidate; break }
            }
            guard let file else { summary.missingFile += 1; continue }
            do {
                let tags = try runner.read(file: file)
                if let values = parse(tags), !values.isEmpty {
                    try store.updateMetadata(clipID: clip.id, merging: values)
                    summary.read += 1
                } else {
                    summary.unsupported += 1
                }
            } catch let e as MetadataError {
                if case .toolMissing = e { throw e }
                summary.failed.append("\(clip.name): \(e)")
            }
        }
        progress?(clips.count, clips.count)
        return summary
    }
}
