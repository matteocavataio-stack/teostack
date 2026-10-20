import Foundation

/// Esegue `art-cmd export` (ARRI Reference Tool CMD) in sola lettura sul file e legge il JSON dei metadata.
/// L'export va in una cartella temporanea che viene sempre eliminata; `--duration 1` limita i metadata per-fotogramma al primo.
public struct ARTCmdRunner {
    public let executable: String
    public var timeout: TimeInterval = 180

    public init(executable: String) {
        self.executable = executable
    }

    public static func locate() -> ARTCmdRunner? {
        ExternalTools.detect(.artCmd).path.map(ARTCmdRunner.init)
    }

    public func read(file: String) throws -> [String: Any] {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw MetadataError.toolMissing("art-cmd non trovato in «\(executable)».")
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("teostack-art-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let output = work.appendingPathComponent("metadata.json")
        let logOut = work.appendingPathComponent("stdout.log"), logErr = work.appendingPathComponent("stderr.log")
        FileManager.default.createFile(atPath: logOut.path, contents: nil)
        FileManager.default.createFile(atPath: logErr.path, contents: nil)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = ["export", "--input", file, "--duration", "1", "--output", output.path]
        p.currentDirectoryURL = work
        let outHandle = try FileHandle(forWritingTo: logOut), errHandle = try FileHandle(forWritingTo: logErr)
        p.standardOutput = outHandle
        p.standardError = errHandle
        defer { try? outHandle.close(); try? errHandle.close() }

        do { try p.run() } catch {
            throw MetadataError.toolFailed("Impossibile avviare art-cmd: \(error.localizedDescription)")
        }
        let deadline = DispatchTime.now() + timeout
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { p.waitUntilExit(); finished.signal() }
        if finished.wait(timeout: deadline) == .timedOut {
            p.terminate()
            throw MetadataError.toolFailed("art-cmd non ha risposto entro \(Int(timeout)) secondi.")
        }
        guard p.terminationStatus == 0 else {
            let log = (try? String(contentsOf: logErr)) ?? ""
            let fallback = (try? String(contentsOf: logOut)) ?? ""
            let text = (log.isEmpty ? fallback : log).trimmingCharacters(in: .whitespacesAndNewlines)
            throw MetadataError.toolFailed("art-cmd ha fallito (codice \(p.terminationStatus))\(text.isEmpty ? "" : ": \(String(text.suffix(300)))")")
        }
        guard let data = try? Data(contentsOf: output),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw MetadataError.invalidOutput("art-cmd non ha prodotto un JSON di metadata valido.")
        }
        return json
    }
}
