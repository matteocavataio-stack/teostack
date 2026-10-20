import Foundation

/// Programmi esterni usati per leggere i metadata. Non vengono inclusi nell'app: se mancano l'app avvisa.
public enum ExternalTool: String, CaseIterable, Identifiable {
    case exiftool
    case ffprobe

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .exiftool: return "ExifTool"
        case .ffprobe: return "ffprobe"
        }
    }

    /// A cosa serve; `isRequired` = senza di esso i metadata non vengono letti.
    public var purpose: String {
        switch self {
        case .exiftool: return "legge i metadata dei clip ARRI e Sony (necessario)"
        case .ffprobe: return "legge i dati tecnici degli MXF Sony e dei file ProRes (consigliato)"
        }
    }

    public var isRequired: Bool { self == .exiftool }

    var versionArguments: [String] {
        switch self {
        case .exiftool: return ["-ver"]
        case .ffprobe: return ["-version"]
        }
    }

    public var installInstructions: String {
        switch self {
        case .exiftool:
            return """
            cd ~/Downloads
            curl -L -o ExifTool-13.59.pkg "https://sourceforge.net/projects/exiftool/files/ExifTool-13.59.pkg/download"
            open ExifTool-13.59.pkg
            (poi, per verifica: exiftool -ver)
            """
        case .ffprobe:
            return """
            cd ~/Downloads
            curl -L -o ffprobe-9.0.2.zip "https://evermeet.cx/ffmpeg/ffprobe-9.0.2.zip"
            unzip -o ffprobe-9.0.2.zip
            sudo mkdir -p /usr/local/bin
            sudo mv ffprobe /usr/local/bin/
            (poi, per verifica: ffprobe -version)
            """
        }
    }
}

public struct ToolStatus: Identifiable, Equatable {
    public let tool: ExternalTool
    public let path: String?
    public let version: String?
    public var id: String { tool.rawValue }
    public var isAvailable: Bool { path != nil }
}

public enum ExternalTools {
    /// Cartelle dove cercare, oltre al PATH (le app lanciate dal Finder non ereditano il PATH del Terminale).
    public static let defaultSearchDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]

    public static func detect(_ tool: ExternalTool,
                              searchDirectories: [String] = defaultSearchDirectories,
                              pathEnvironment: String? = ProcessInfo.processInfo.environment["PATH"]) -> ToolStatus {
        var dirs = searchDirectories
        for d in (pathEnvironment ?? "").split(separator: ":").map(String.init) where !dirs.contains(d) { dirs.append(d) }
        for dir in dirs {
            let candidate = (dir as NSString).appendingPathComponent(tool.rawValue)
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            if let version = run(candidate, arguments: tool.versionArguments) {
                return ToolStatus(tool: tool, path: candidate, version: version)
            }
        }
        return ToolStatus(tool: tool, path: nil, version: nil)
    }

    public static func detectAll(searchDirectories: [String] = defaultSearchDirectories,
                                 pathEnvironment: String? = ProcessInfo.processInfo.environment["PATH"]) -> [ToolStatus] {
        ExternalTool.allCases.map { detect($0, searchDirectories: searchDirectories, pathEnvironment: pathEnvironment) }
    }

    /// Esegue il programma e restituisce la prima riga dell'output, o nil se non parte o termina con errore.
    static func run(_ path: String, arguments: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let first = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).first.map(String.init)
        return first?.trimmingCharacters(in: .whitespaces)
    }
}
