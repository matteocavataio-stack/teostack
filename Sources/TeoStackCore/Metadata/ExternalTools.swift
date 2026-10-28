import Foundation

/// Programmi esterni usati per leggere i metadata. L'installer include ExifTool, ffmpeg e ffprobe (Resources/tools); art-cmd (ARRI) viene scaricato da ARRI. Se manca qualcosa l'app avvisa.
public enum ExternalTool: String, CaseIterable, Identifiable {
    case exiftool
    case ffprobe
    case ffmpeg
    case artCmd

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .exiftool: return "ExifTool"
        case .ffprobe: return "ffprobe"
        case .ffmpeg: return "ffmpeg"
        case .artCmd: return "art-cmd (ARRI Reference Tool)"
        }
    }

    /// Nome del file eseguibile.
    public var executableName: String {
        switch self {
        case .exiftool: return "exiftool"
        case .ffprobe: return "ffprobe"
        case .ffmpeg: return "ffmpeg"
        case .artCmd: return "art-cmd"
        }
    }

    /// A cosa serve; `isRequired` = senza di esso i metadata non vengono letti.
    public var purpose: String {
        switch self {
        case .exiftool: return tr("legge i metadata dei clip ARRI e Sony (necessario)")
        case .ffprobe: return tr("legge i dati tecnici degli MXF Sony e dei file ProRes (consigliato)")
        case .ffmpeg: return tr("estrae il primo fotogramma dei clip ProRes e Sony per l'anteprima (consigliato)")
        case .artCmd: return tr("legge i metadata dei clip ARRI (ISO, lente, ND, WB, look, sensor FPS) e ne ricava l'anteprima ARRIRAW/ARRICORE")
        }
    }

    public var isRequired: Bool { self == .exiftool }

    /// nil = non si esegue il programma per verificarlo (basta che il file esista ed sia eseguibile).
    var versionArguments: [String]? {
        switch self {
        case .exiftool: return ["-ver"]
        case .ffprobe, .ffmpeg: return ["-version"]
        case .artCmd: return nil
        }
    }

    public var installInstructions: String {
        switch self {
        case .exiftool:
            return """
            cd ~/Downloads
            curl -L -o ExifTool-13.59.pkg "https://sourceforge.net/projects/exiftool/files/ExifTool-13.59.pkg/download"
            open ExifTool-13.59.pkg
            \(tr("(poi, per verifica: {0})", "exiftool -ver"))
            """
        case .ffprobe:
            return """
            cd ~/Downloads
            curl -L -o ffprobe-9.0.2.zip "https://evermeet.cx/ffmpeg/ffprobe-9.0.2.zip"
            unzip -o ffprobe-9.0.2.zip
            sudo mkdir -p /usr/local/bin
            sudo mv ffprobe /usr/local/bin/
            \(tr("(poi, per verifica: {0})", "ffprobe -version"))
            """
        case .ffmpeg:
            return """
            cd ~/Downloads
            curl -L -o ffmpeg-9.0.2.zip "https://evermeet.cx/ffmpeg/ffmpeg-9.0.2.zip"
            unzip -o ffmpeg-9.0.2.zip
            sudo mkdir -p /usr/local/bin
            sudo mv ffmpeg /usr/local/bin/
            \(tr("(poi, per verifica: {0})", "ffmpeg -version"))
            """
        case .artCmd:
            return """
            mkdir -p ~/ARRI
            cd ~/ARRI
            curl -L -o art-cmd.zip "https://arri.canto.de/direct/other/ht9rmfr4q177f2jlct7alob95s/AXAAWD6V5zGk08YuSogjUy6PcKM/original?content-type=application%2Fzip&name=ARRIReferenceTool_CMD_1.0.0_macos_universal_data.zip"
            unzip -q art-cmd.zip
            \(tr("(tieni l'intera cartella {0}: art-cmd ha bisogno della sottocartella lib)", "~/ARRI/art-cmd_1.0.0_macos_universal"))
            \(tr("(se macOS lo blocca: {0})", "xattr -dr com.apple.quarantine ~/ARRI"))
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
    public static var defaultSearchDirectories: [String] { bundledToolsDirectories + systemSearchDirectories }

    static let systemSearchDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]

    /// Strumenti inclusi nell'app installata (TeoStackXt.app/Contents/Resources/tools): hanno la precedenza su quelli di sistema.
    public static var bundledToolsDirectories: [String] {
        guard let resources = Bundle.main.resourcePath else { return [] }
        let tools = resources + "/tools"
        return FileManager.default.fileExists(atPath: tools) ? [tools] : []
    }

    /// Percorso scelto a mano dall'utente per un programma (UserDefaults, chiave "toolPath.<nome>").
    public static func userPath(for tool: ExternalTool) -> String? {
        UserDefaults.standard.string(forKey: "toolPath.\(tool.rawValue)")
    }

    public static func setUserPath(_ path: String?, for tool: ExternalTool) {
        UserDefaults.standard.set(path, forKey: "toolPath.\(tool.rawValue)")
    }

    /// Dove cercare art-cmd: il pacchetto ARRI si scompatta in una cartella con bin/ e lib/ (es. ~/ARRI/art-cmd_1.0.0_macos_universal/bin).
    public static func artCmdSearchDirectories(home: String = NSHomeDirectory()) -> [String] {
        var result: [String] = []
        for base in [home + "/ARRI", "/Applications/ARRI", "/opt/ARRI", "/usr/local/ARRI"] {
            let entries = ((try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []).sorted(by: >)   // versioni più recenti prima
            for e in entries { result.append(base + "/" + e + "/bin") }
            result.append(base + "/bin")
        }
        return result
    }

    public static func detect(_ tool: ExternalTool,
                              searchDirectories: [String] = defaultSearchDirectories,
                              pathEnvironment: String? = ProcessInfo.processInfo.environment["PATH"],
                              userPath: String? = nil) -> ToolStatus {
        var candidates: [String] = []
        if let userPath = userPath ?? Self.userPath(for: tool) { candidates.append(userPath) }
        var dirs = searchDirectories
        if tool == .artCmd && searchDirectories == defaultSearchDirectories { dirs += artCmdSearchDirectories() }
        for d in (pathEnvironment ?? "").split(separator: ":").map(String.init) where !dirs.contains(d) { dirs.append(d) }
        candidates += dirs.map { ($0 as NSString).appendingPathComponent(tool.executableName) }
        for candidate in candidates {
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            guard let args = tool.versionArguments else {
                return ToolStatus(tool: tool, path: candidate, version: nil)
            }
            if let version = run(candidate, arguments: args) {
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
