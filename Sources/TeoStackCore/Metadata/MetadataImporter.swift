import Foundation

public struct MetadataSummary: Equatable {
    public var read = 0                   // clip con almeno un metadata letto
    public var unsupported = 0            // formato non riconosciuto da nessun parser: nessun valore scritto
    public var missingFile = 0            // file di destinazione non raggiungibile (disco scollegato?)
    public var failed: [String] = []      // errori di lettura "clip: messaggio"
    public var artFailed: [String] = []   // clip ARRI per cui art-cmd ha fallito: restano solo i dati di ExifTool

    public var text: String {
        var parts = ["\(read) clip letti"]
        if unsupported > 0 { parts.append(tr("{0} formato non supportato ({1})", unsupported, ClipColumns.notAvailable)) }
        if missingFile > 0 { parts.append(tr("{0} file non raggiungibili", missingFile)) }
        if !artFailed.isEmpty { parts.append(tr("art-cmd non ha letto {0} clip ARRI (ISO, lente, ND, WB… {1})", artFailed.count, ClipColumns.notAvailable)) }
        if !failed.isEmpty { parts.append("\(failed.count) errori") }
        return parts.joined(separator: ", ")
    }
}

/// Legge i metadata dei clip e li salva nel database.
/// Si legge la COPIA verificata sulla destinazione (mai la scheda sorgente) e solo in lettura.
///
/// Per ogni clip: ExifTool riconosce la famiglia e dà i dati del contenitore (durata, FPS del file…);
/// per i clip ARRI `art-cmd` (se installato) aggiunge ISO, lente, ND, WB, look, sensor FPS… e prevale dove i dati si sovrappongono.
/// Per tutto il resto (MPG, WAV/BWF, LRF, MP4, ProRes…) legge `ffprobe`: codec, risoluzione, frame rate, durata e audio dai dati veri del file
/// (ExifTool sui file MPEG sbaglia, per esempio, codec e frequenza dell'audio: per questo non si usa per questi formati).
public enum MetadataImporter {
    /// Estensioni su cui provare art-cmd quando ExifTool non è disponibile o non riconosce il file.
    static let artCmdExtensions: Set<String> = ["mxf", "mov"]

    public static func importMetadata(for clips: [ClipRecord], store: ProjectStore,
                                      runner: ExifToolRunner?, art: ARTCmdRunner? = nil, probe: FFprobeRunner? = nil,
                                      progress: ((Int, Int) -> Void)? = nil) throws -> MetadataSummary {
        if runner == nil && art == nil && probe == nil {
            throw MetadataError.toolMissing(tr("Né ExifTool né art-cmd né ffprobe sono installati: impossibile leggere i metadata."))
        }
        var summary = MetadataSummary()
        let registry = ReaderRegistry.standard()
        var rootsCache: [Int64: [String]] = [:]
        var done = 0
        let lock = NSLock()
        // Un clip alla volta per lavoratore: ExifTool e art-cmd partono in parallelo su più clip (la lettura è quasi tutta attesa).
        try ParallelRunner.forEach(clips) { _, clip in
            defer {
                lock.lock(); done += 1; let n = done; lock.unlock()
                progress?(n, clips.count)
            }
            guard clip.isMedia || clip.isAudio || MediaClassifier.isMetadataReadable(relativePath: clip.relativePath), clip.hasLocalFile else { return }
            lock.lock(); let cachedRoots = rootsCache[clip.offloadID]; lock.unlock()
            let roots: [String]
            if let cachedRoots { roots = cachedRoots } else {
                roots = try store.destinationRoots(offloadID: clip.offloadID)
                lock.lock(); rootsCache[clip.offloadID] = roots; lock.unlock()
            }
            // prima copia verificata OK (o file importato) che esiste ancora su disco
            var file: String?
            for (d, root) in roots.enumerated() where clip.fileAvailable(onDestination: d) {
                let candidate = (root as NSString).appendingPathComponent(clip.relativePath)
                if FileManager.default.fileExists(atPath: candidate) { file = candidate; break }
            }
            guard let file else { lock.lock(); summary.missingFile += 1; lock.unlock(); return }

            let tools = ReaderTools(exiftool: runner, ffprobe: probe, artCmd: art)
            let result = registry.read(ClipFile(url: URL(fileURLWithPath: file), tools: tools))
            var firstError: String?
            for diagnostic in result.diagnostics {
                switch diagnostic {
                case .toolMissing(let message): throw MetadataError.toolMissing(message)
                case .toolFailed(let message): if firstError == nil { firstError = "\(clip.name): \(message)" }
                case .artCmdFailed(let message):
                    lock.lock()
                    summary.artFailed.append(message.map { "\(clip.name): \($0)" } ?? tr("{0}: art-cmd non ha restituito metadata", clip.name))
                    lock.unlock()
                case .note: break
                }
            }
            let values = result.columns
            if values.isEmpty {
                lock.lock()
                if let firstError { summary.failed.append(firstError) } else { summary.unsupported += 1 }
                lock.unlock()
            } else {
                try store.updateMetadata(clipID: clip.id, merging: values)
                lock.lock(); summary.read += 1; lock.unlock()
            }
        }
        summary.failed.sort()
        summary.artFailed.sort()
        return summary
    }
}
