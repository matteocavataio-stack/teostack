import Foundation

/// Esegue `ffprobe -show_format -show_streams -of json <file>` (sola lettura) e restituisce il JSON come dizionario.
/// Serve per i formati senza un parser dedicato (MPG, WAV/BWF, LRF, MP4, ProRes…): ffprobe dà codec, risoluzione, frame rate, durata e audio
/// calcolati dai fotogrammi veri, non stimati dai byte del file.
public struct FFprobeRunner {
    public let executable: String
    public var timeout: TimeInterval = 60

    public init(executable: String) {
        self.executable = executable
    }

    public static func locate() -> FFprobeRunner? {
        ExternalTools.detect(.ffprobe).path.map(FFprobeRunner.init)
    }

    public func read(file: String) throws -> [String: Any] {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw MetadataError.toolMissing(tr("ffprobe non trovato in «{0}».", executable))
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = ["-v", "error", "-show_format", "-show_streams", "-of", "json", file]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch {
            throw MetadataError.toolFailed(tr("Impossibile avviare ffprobe: {0}", error.localizedDescription))
        }
        let output = Output()
        let reading = DispatchGroup()
        reading.enter(); DispatchQueue.global().async { output.data = out.fileHandleForReading.readDataToEndOfFile(); reading.leave() }
        reading.enter(); DispatchQueue.global().async { output.errorData = err.fileHandleForReading.readDataToEndOfFile(); reading.leave() }
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { p.waitUntilExit(); finished.signal() }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            throw MetadataError.toolFailed(tr("ffprobe non ha risposto entro {0} secondi.", Int(timeout)))
        }
        reading.wait()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: output.errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw MetadataError.toolFailed(msg.isEmpty ? tr("ffprobe non riconosce il file.") : tr("ffprobe non riconosce il file: {0}", String(msg.suffix(250))))
        }
        return try FFprobeRunner.parse(output.data)
    }

    /// Contenitore per i due flussi letti in parallelo (ognuno scritto da un solo lavoro, letto dopo `reading.wait()`).
    private final class Output: @unchecked Sendable {
        var data = Data()
        var errorData = Data()
    }

    public static func parse(_ data: Data) throws -> [String: Any] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MetadataError.invalidOutput(tr("L'output di ffprobe non è un JSON valido."))
        }
        return json
    }
}
