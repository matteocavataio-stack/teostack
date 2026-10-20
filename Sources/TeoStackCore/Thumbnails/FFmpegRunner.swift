import Foundation

/// Estrae il primo fotogramma di un video con ffmpeg (ProRes, Sony XAVC, H.264…): lettura del file, scrittura solo del JPEG indicato.
public struct FFmpegRunner {
    public let executable: String
    public var timeout: TimeInterval = 120

    public init(executable: String) {
        self.executable = executable
    }

    public static func locate() -> FFmpegRunner? {
        ExternalTools.detect(.ffmpeg).path.map(FFmpegRunner.init)
    }

    /// Primo fotogramma del video → JPEG largo al massimo `maxWidth` pixel.
    public func extractFirstFrame(from file: String, to output: String, maxWidth: Int) throws {
        try run(["-hide_banner", "-loglevel", "error", "-y", "-i", file, "-an", "-frames:v", "1",
                 "-vf", "scale='min(\(maxWidth),iw)':-2,format=yuvj420p", "-q:v", "3", output], output: output)
    }

    /// Ridimensiona un'immagine (es. il TIFF a 16 bit di art-cmd) in JPEG: usato dove non c'è ImageIO (Linux).
    public func convertImage(from file: String, to output: String, maxWidth: Int) throws {
        try run(["-hide_banner", "-loglevel", "error", "-y", "-i", file, "-frames:v", "1",
                 "-vf", "scale='min(\(maxWidth),iw)':-2,format=yuvj420p", "-q:v", "3", output], output: output)
    }

    private func run(_ arguments: [String], output: String) throws {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw MetadataError.toolMissing("ffmpeg non trovato in «\(executable)».")
        }
        try? FileManager.default.removeItem(atPath: output)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("teostack-ffmpeg-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: log) }
        let handle = try FileHandle(forWritingTo: log)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = handle
        defer { try? handle.close() }
        do { try p.run() } catch { throw MetadataError.toolFailed("Impossibile avviare ffmpeg: \(error.localizedDescription)") }
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { p.waitUntilExit(); finished.signal() }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            throw MetadataError.toolFailed("ffmpeg non ha risposto entro \(Int(timeout)) secondi.")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: output)[.size] as? Int) ?? 0
        guard p.terminationStatus == 0, (size ?? 0) > 0 else {
            try? FileManager.default.removeItem(atPath: output)
            let text = ((try? String(contentsOf: log)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            throw MetadataError.toolFailed("ffmpeg non ha estratto il fotogramma\(text.isEmpty ? "" : ": \(String(text.suffix(250)))")")
        }
    }
}
