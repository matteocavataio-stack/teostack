import Foundation

/// Esegue `art-cmd` (ARRI Reference Tool CMD) in sola lettura sul file:
/// - `export`: legge i metadata in un JSON (solo il primo fotogramma, `--duration 1`);
/// - `process`: renderizza il primo fotogramma in un'immagine per l'anteprima.
/// Ogni esecuzione lavora in una cartella temporanea che viene sempre eliminata.
public struct ARTCmdRunner {
    public let executable: String
    public var timeout: TimeInterval = 180

    public init(executable: String) {
        self.executable = executable
    }

    public static func locate() -> ARTCmdRunner? {
        ExternalTools.detect(.artCmd).path.map(ARTCmdRunner.init)
    }

    // MARK: Metadata

    public func read(file: String) throws -> [String: Any] {
        try withWorkDirectory { work in
            let output = work.appendingPathComponent("metadata.json")
            try execute(["export", "--input", file, "--duration", "1", "--output", output.path], in: work)
            guard let data = try? Data(contentsOf: output),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw MetadataError.invalidOutput(tr("art-cmd non ha prodotto un JSON di metadata valido."))
            }
            return json
        }
    }

    // MARK: Anteprima

    /// Renderizza il primo fotogramma in Rec.709 e lo passa a `consume` (il file temporaneo viene eliminato subito dopo).
    /// Prova prima con il look incorporato nel clip (quello che il DIT vede sul monitor), poi senza look.
    public func renderFirstFrame<T>(file: String, consume: (URL) throws -> T) throws -> T {
        try withWorkDirectory { work in
            let attempts: [[String]] = [
                ["--embedded-look", "--target-colorspace", "Rec.709/D65/BT.1886"],
                ["--target-colorspace", "Rec.709/D65/BT.1886"],
            ]
            var lastError: Error?
            for (n, extra) in attempts.enumerated() {
                let out = work.appendingPathComponent("frame\(n)", isDirectory: true)
                try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                do {
                    try execute(["process", "--input", file, "--start", "0", "--duration", "1"] + extra
                                + ["--output", out.appendingPathComponent("%07d.tif").path], in: work)
                    let produced = ((try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []).sorted().first { $0.lowercased().hasSuffix(".tif") }
                    guard let produced else { throw MetadataError.invalidOutput(tr("art-cmd non ha prodotto alcuna immagine.")) }
                    return try consume(out.appendingPathComponent(produced))
                } catch { lastError = error }
            }
            throw lastError ?? MetadataError.toolFailed(tr("art-cmd non ha prodotto l'anteprima."))
        }
    }

    // MARK: Esecuzione

    private func withWorkDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw MetadataError.toolMissing(tr("art-cmd non trovato in «{0}».", executable))
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("teostack-art-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        return try body(work)
    }

    private func execute(_ arguments: [String], in work: URL) throws {
        let logOut = work.appendingPathComponent("stdout.log"), logErr = work.appendingPathComponent("stderr.log")
        FileManager.default.createFile(atPath: logOut.path, contents: nil)
        FileManager.default.createFile(atPath: logErr.path, contents: nil)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.currentDirectoryURL = work
        let outHandle = try FileHandle(forWritingTo: logOut), errHandle = try FileHandle(forWritingTo: logErr)
        p.standardOutput = outHandle
        p.standardError = errHandle
        defer { try? outHandle.close(); try? errHandle.close() }

        do { try p.run() } catch {
            throw MetadataError.toolFailed(tr("Impossibile avviare art-cmd: {0}", error.localizedDescription))
        }
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { p.waitUntilExit(); finished.signal() }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            throw MetadataError.toolFailed(tr("art-cmd non ha risposto entro {0} secondi.", Int(timeout)))
        }
        guard p.terminationStatus == 0 else {
            let log = (try? String(contentsOf: logErr)) ?? ""
            let fallback = (try? String(contentsOf: logOut)) ?? ""
            let text = (log.isEmpty ? fallback : log).trimmingCharacters(in: .whitespacesAndNewlines)
            throw MetadataError.toolFailed("art-cmd ha fallito (codice \(p.terminationStatus))\(text.isEmpty ? "" : ": \(String(text.suffix(300)))")")
        }
    }
}
