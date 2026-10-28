import Foundation

public struct ThumbnailTools {
    public var art: ARTCmdRunner?
    public var ffmpeg: FFmpegRunner?

    public init(art: ARTCmdRunner? = ARTCmdRunner.locate(), ffmpeg: FFmpegRunner? = FFmpegRunner.locate()) {
        self.art = art
        self.ffmpeg = ffmpeg
    }
}

public struct ThumbnailSummary: Equatable {
    public var generated = 0
    public var alreadyPresent = 0
    public var missingFile = 0
    public var failed: [String] = []      // "clip: motivo"

    public var text: String {
        var parts = [tr("{0} anteprime create", generated)]
        if alreadyPresent > 0 { parts.append(tr("{0} già presenti", alreadyPresent)) }
        if missingFile > 0 { parts.append(tr("{0} file non raggiungibili", missingFile)) }
        if !failed.isEmpty { parts.append(tr("{0} non decodificabili (vedi il motivo nel pannello di anteprima)", failed.count)) }
        return parts.joined(separator: ", ")
    }
}

/// Anteprima del PRIMO fotogramma di un clip.
/// - Clip ARRI: `art-cmd process` (decodifica ARRIRAW/ARRICORE, look incorporato, Rec.709), poi ridotto a JPEG.
/// - Altri video (ProRes, Sony XAVC…) e ripiego per i clip ARRI: ffmpeg.
/// - Dove nessuno strumento riesce a decodificare, l'anteprima manca e il motivo viene registrato: nessuna immagine inventata.
public enum ThumbnailGenerator {
    public static let maxWidth = 640

    public static func generate(clip: ClipRecord, file: String, tools: ThumbnailTools, cache: ThumbnailCache) throws {
        let output = cache.imageURL(clipID: clip.id)
        try cache.ensureDirectory()
        let ext = (clip.relativePath as NSString).pathExtension.lowercased()
        let looksARRI = (clip.metadata["camera"] ?? "").uppercased().contains("ARRI") || ext == "ari" || ext == "arx"

        var reasons: [String] = []
        func succeed() { cache.clearFailure(clipID: clip.id) }

        if looksARRI, let art = tools.art {
            do {
                try art.renderFirstFrame(file: file) { tiff in
                    try ThumbnailImage.makeJPEG(from: tiff, to: output, maxWidth: maxWidth, ffmpeg: tools.ffmpeg)
                }
                succeed()
                return
            } catch { reasons.append("art-cmd: \(error)") }
        } else if looksARRI {
            reasons.append(tr("per i clip ARRI serve art-cmd (ARRI Reference Tool), non installato"))
        }

        if let ffmpeg = tools.ffmpeg {
            do {
                try ffmpeg.extractFirstFrame(from: file, to: output.path, maxWidth: maxWidth)
                succeed()
                return
            } catch { reasons.append("ffmpeg: \(error)") }
        } else {
            reasons.append(tr("ffmpeg non installato"))
        }

        let reason = tr("Anteprima non disponibile: formato non decodificabile con gli strumenti installati.") + " " + reasons.joined(separator: " · ")
        cache.recordFailure(clipID: clip.id, reason: reason)
        throw MetadataError.toolFailed(reason)
    }

    /// Crea le anteprime dei clip video verificati (dalla copia sul disco di destinazione, mai dalla scheda).
    public static func generate(for clips: [ClipRecord], store: ProjectStore, tools: ThumbnailTools, cache: ThumbnailCache,
                                regenerate: Bool = false, progress: ((Int, Int) -> Void)? = nil) throws -> ThumbnailSummary {
        if tools.art == nil && tools.ffmpeg == nil {
            throw MetadataError.toolMissing(tr("Né ffmpeg né art-cmd sono installati: impossibile creare le anteprime."))
        }
        var summary = ThumbnailSummary()
        var rootsCache: [Int64: [String]] = [:]
        var done = 0
        let lock = NSLock()
        // Più anteprime in parallelo (art-cmd e ffmpeg sono programmi esterni che lavorano ciascuno per conto proprio).
        try ParallelRunner.forEach(clips) { _, clip in
            defer {
                lock.lock(); done += 1; let n = done; lock.unlock()
                progress?(n, clips.count)
            }
            guard clip.isMedia, clip.hasLocalFile else { return }
            if !regenerate && cache.hasImage(clipID: clip.id) { lock.lock(); summary.alreadyPresent += 1; lock.unlock(); return }
            lock.lock(); let cachedRoots = rootsCache[clip.offloadID]; lock.unlock()
            let roots: [String]
            if let cachedRoots { roots = cachedRoots } else {
                roots = try store.destinationRoots(offloadID: clip.offloadID)
                lock.lock(); rootsCache[clip.offloadID] = roots; lock.unlock()
            }
            var file: String?
            for (d, root) in roots.enumerated() where clip.fileAvailable(onDestination: d) {
                let candidate = (root as NSString).appendingPathComponent(clip.relativePath)
                if FileManager.default.fileExists(atPath: candidate) { file = candidate; break }
            }
            guard let file else { lock.lock(); summary.missingFile += 1; lock.unlock(); return }
            do {
                try generate(clip: clip, file: file, tools: tools, cache: cache)
                lock.lock(); summary.generated += 1; lock.unlock()
            } catch let e as MetadataError {
                if case .toolMissing = e { throw e }
                lock.lock(); summary.failed.append("\(clip.name): \(e)"); lock.unlock()
            }
        }
        summary.failed.sort()
        return summary
    }
}
