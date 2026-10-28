import Foundation

public enum MetadataError: Error, CustomStringConvertible, Equatable {
    case toolMissing(String)
    case toolFailed(String)
    case invalidOutput(String)

    public var description: String {
        switch self {
        case .toolMissing(let m), .toolFailed(let m), .invalidOutput(let m): return m
        }
    }
}

/// Esegue `exiftool -json -G1 -n <file>` (sola lettura) e restituisce i tag come dizionario "Gruppo:Nome" → valore.
public struct ExifToolRunner {
    public let executable: String

    public init(executable: String) {
        self.executable = executable
    }

    public static func locate() -> ExifToolRunner? {
        ExternalTools.detect(.exiftool).path.map(ExifToolRunner.init)
    }

    /// Tempo massimo per la lettura dei dati incorporati nel flusso (`-ee`) di un file.
    public var embeddedTimeout: TimeInterval = 90

    /// Tutti i tag del file (anche duplicati e sconosciuti, valori grezzi). Con `embedded` anche i dati registrati dentro il flusso (`-ee`),
    /// per esempio il flusso «djmd» dei DJI: lento sui file enormi, quindi con un tempo massimo.
    public func read(file: String, embedded: Bool = false) throws -> [String: Any] {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw MetadataError.toolMissing(tr("ExifTool non trovato in «{0}».", executable))
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = ["-json", "-G1", "-a", "-u", "-n"] + (embedded ? ["-ee"] : []) + [file]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch {
            throw MetadataError.toolFailed(tr("Impossibile avviare ExifTool: {0}", error.localizedDescription))
        }
        var timedOut = false
        let killer = DispatchWorkItem { timedOut = true; if p.isRunning { p.terminate() } }
        if embedded { DispatchQueue.global().asyncAfter(deadline: .now() + embeddedTimeout, execute: killer) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        if timedOut { throw MetadataError.toolFailed(tr("ExifTool non ha risposto entro {0} secondi.", Int(embeddedTimeout))) }
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw MetadataError.toolFailed("ExifTool ha fallito (codice \(p.terminationStatus))\(msg.isEmpty ? "" : ": \(msg)")")
        }
        return try ExifToolRunner.parse(data)
    }

    public static func parse(_ data: Data) throws -> [String: Any] {
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let array = json as? [[String: Any]], let first = array.first else {
            throw MetadataError.invalidOutput(tr("L'output di ExifTool non è un JSON valido."))
        }
        return first
    }
}
