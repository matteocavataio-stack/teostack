import Foundation

public struct MetadataSummary: Equatable {
    public var read = 0                   // clip con almeno un metadata letto
    public var unsupported = 0            // formato non riconosciuto da nessun parser: nessun valore scritto
    public var missingFile = 0            // file di destinazione non raggiungibile (disco scollegato?)
    public var failed: [String] = []      // errori di lettura "clip: messaggio"
    public var artFailed: [String] = []   // clip ARRI per cui art-cmd ha fallito: restano solo i dati di ExifTool

    public var text: String {
        var parts = ["\(read) clip letti"]
        if unsupported > 0 { parts.append("\(unsupported) formato non supportato (N/D)") }
        if missingFile > 0 { parts.append("\(missingFile) file non raggiungibili") }
        if !artFailed.isEmpty { parts.append("art-cmd non ha letto \(artFailed.count) clip ARRI (ISO, lente, ND, WB… N/D)") }
        if !failed.isEmpty { parts.append("\(failed.count) errori") }
        return parts.joined(separator: ", ")
    }
}

/// Legge i metadata dei clip e li salva nel database.
/// Si legge la COPIA verificata sulla destinazione (mai la scheda sorgente) e solo in lettura.
///
/// Per ogni clip: ExifTool riconosce la famiglia e dà i dati del contenitore (durata, FPS del file…);
/// per i clip ARRI `art-cmd` (se installato) aggiunge ISO, lente, ND, WB, look, sensor FPS… e prevale dove i dati si sovrappongono.
public enum MetadataImporter {
    /// Estensioni su cui provare art-cmd quando ExifTool non è disponibile o non riconosce il file.
    static let artCmdExtensions: Set<String> = ["mxf", "mov"]

    public static func importMetadata(for clips: [ClipRecord], store: ProjectStore,
                                      runner: ExifToolRunner?, art: ARTCmdRunner? = nil,
                                      progress: ((Int, Int) -> Void)? = nil) throws -> MetadataSummary {
        if runner == nil && art == nil {
            throw MetadataError.toolMissing("Né ExifTool né art-cmd sono installati: impossibile leggere i metadata.")
        }
        var summary = MetadataSummary()
        var rootsCache: [Int64: [String]] = [:]
        for (index, clip) in clips.enumerated() {
            progress?(index, clips.count)
            guard clip.isMedia, clip.status == "ok" else { continue }
            let roots: [String]
            if let cached = rootsCache[clip.offloadID] { roots = cached } else {
                roots = try store.destinationRoots(offloadID: clip.offloadID)
                rootsCache[clip.offloadID] = roots
            }
            // prima copia verificata OK che esiste ancora su disco
            var file: String?
            for (d, root) in roots.enumerated() where d < clip.destinationStatuses.count && clip.destinationStatuses[d] == "ok" {
                let candidate = (root as NSString).appendingPathComponent(clip.relativePath)
                if FileManager.default.fileExists(atPath: candidate) { file = candidate; break }
            }
            guard let file else { summary.missingFile += 1; continue }

            var values: [String: String] = [:]
            var isARRI = false
            var exifFailed = false
            if let runner {
                do {
                    let tags = try runner.read(file: file)
                    if ARRIMetadataParser.canParse(tags) {
                        isARRI = true
                        values = ARRIMetadataParser.parse(tags)
                    }
                } catch let e as MetadataError {
                    if case .toolMissing = e { throw e }
                    summary.failed.append("\(clip.name): \(e)")
                    exifFailed = true
                }
            }
            if exifFailed && art == nil { continue }

            let ext = (clip.relativePath as NSString).pathExtension.lowercased()
            if let art, isARRI || (values.isEmpty && artCmdExtensions.contains(ext)) {
                do {
                    let json = try art.read(file: file)
                    let extra = ARTMetadataParser.parse(json)
                    if !extra.isEmpty {
                        values.merge(extra) { _, new in new }
                    } else if isARRI {
                        summary.artFailed.append("\(clip.name): art-cmd non ha restituito metadata")
                    }
                } catch let e as MetadataError {
                    if case .toolMissing = e { throw e }
                    // su un clip riconosciuto come ARRI l'errore va segnalato; su un file sconosciuto è solo "formato non supportato"
                    if isARRI { summary.artFailed.append("\(clip.name): \(e)") }
                }
            }
            if values.isEmpty {
                if !exifFailed { summary.unsupported += 1 }
            } else {
                try store.updateMetadata(clipID: clip.id, merging: values)
                summary.read += 1
            }
        }
        progress?(clips.count, clips.count)
        return summary
    }
}
