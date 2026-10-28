import Foundation

/// Problema incontrato leggendo un file (non è un errore del file: serve a riepilogo e diagnosi).
public enum MetadataDiagnostic: Equatable {
    /// Un programma esterno richiesto non è installato/eseguibile: la lettura dell'intero lotto si interrompe.
    case toolMissing(String)
    /// Un programma ha fallito sul file (ExifTool, ffprobe…).
    case toolFailed(String)
    /// `art-cmd` non ha letto un clip ARRI: restano solo gli altri dati (nil = ha risposto ma senza metadata).
    case artCmdFailed(String?)
    /// Informazione per chi legge il risultato (es. «implementato ma non verificato»).
    case note(String)
}

/// Metadata di un clip. Ogni campo è opzionale: un valore che il file non dichiara resta `nil`, non viene mai stimato né inventato.
/// Le conversioni da/verso le chiavi del database (`ClipRecord.metadata`) sono in `columns` / `init(columns:)`.
public struct ClipMetadata: Equatable {
    public enum Status: Equatable {
        /// Letto con almeno un campo.
        case read
        /// Formato riconosciuto ma lettura incompleta (strumento mancante, campi non disponibili).
        case partial
        /// Nessun lettore riconosce il file: viene trattato come file generico (solo hash).
        case unsupported
        case failed(String)
    }

    public var status: Status = .unsupported
    /// Famiglia del lettore che ha prodotto il risultato («ARRI», «RED», «Sony»…).
    public var family: String?
    public var diagnostics: [MetadataDiagnostic] = []

    public var clipName: String?
    public var reel: String?
    public var cameraMake: String?
    public var cameraModel: String?
    public var cameraSerial: String?
    public var firmware: String?
    public var codec: String?
    public var container: String?
    public var width: Int?
    public var height: Int?
    public var fps: Double?
    public var timecodeStart: String?
    public var duration: Double?
    public var frameCount: Int?
    public var colorSpace: String?
    public var gamma: String?
    public var iso: String?
    public var whiteBalance: String?
    public var shutter: String?
    public var shutterAngle: String?
    public var lensModel: String?
    public var focalLength: String?
    public var aperture: String?
    public var tStop: String?
    public var focusDistance: String?
    public var cameraTilt: String?
    public var cameraRoll: String?
    public var audioChannels: Int?
    public var audioSampleRate: Int?
    public var bwfTimecode: String?
    public var creationDate: String?
    /// Chiavi del database senza campo tipizzato (scena, take, ND, sensor FPS, look…): si conservano così come sono.
    public var extraColumns: [String: String] = [:]
    /// Tutti gli altri tag trovati nel file, con il nome dato dallo strumento che li ha letti.
    public var rawFields: [String: String] = [:]

    public init() {}

    public static func unsupported(_ diagnostics: [MetadataDiagnostic] = []) -> ClipMetadata {
        var m = ClipMetadata()
        m.diagnostics = diagnostics
        return m
    }

    public var isUnsupported: Bool { status == .unsupported }

    /// Almeno un campo (tipizzato o no) è valorizzato.
    public var hasValues: Bool { !columns.isEmpty }

    // MARK: Chiavi del database

    public static let rawPrefix = "raw."

    /// Chiave del database → campo (solo i campi tipizzati, per i test e per le tabelle di esportazione).
    public static let columnKeys: [(key: String, label: String)] = [
        ("clipName", "Clip name"), ("reel", "Reel"), ("manufacturer", "Camera make"), ("camera", "Camera model"), ("cameraSerial", "Camera serial"),
        ("firmware", "Firmware"), ("codec", "Codec"), ("container", "Container"), ("resolution", "Resolution"), ("frameRate", "FPS"),
        ("timecode", "Timecode start"), ("durationSeconds", "Duration (s)"), ("frameCount", "Frame count"), ("colorSpace", "Color space"),
        ("gamma", "Gamma"), ("iso", "ISO/EI"), ("whiteBalance", "White balance"), ("shutter", "Shutter"), ("shutterAngle", "Shutter angle"),
        ("lens", "Lens"), ("focalLength", "Focal length"), ("aperture", "Aperture"), ("tStop", "T-stop"), ("focusDistance", "Focus distance"),
        ("tilt", "Tilt"), ("roll", "Roll"), ("audioChannels", "Audio channels"), ("audioSampleRate", "Audio sample rate"),
        ("bwfTimecode", "BWF timecode"), ("createDate", "Creation date"),
    ]

    /// Valori nel formato delle chiavi del database (`ClipRecord.metadata`); i campi assenti non compaiono.
    public var columns: [String: String] {
        var out = extraColumns
        func put(_ key: String, _ value: String?) { if let value, !value.isEmpty { out[key] = value } }
        put("clipName", clipName); put("reel", reel); put("manufacturer", cameraMake); put("camera", cameraModel)
        put("cameraSerial", cameraSerial); put("firmware", firmware); put("codec", codec); put("container", container)
        if let width, let height, width > 0, height > 0 { out["resolution"] = "\(width)x\(height)" }
        if let fps { put("frameRate", Self.trimmed(fps, decimals: 3)) }
        put("timecode", timecodeStart ?? bwfTimecode)
        if let duration { put("durationSeconds", Self.trimmed(duration, decimals: 3)) }
        if let frameCount { out["frameCount"] = String(frameCount) }
        put("colorSpace", colorSpace); put("gamma", gamma); put("iso", iso); put("whiteBalance", whiteBalance)
        put("shutter", shutter); put("shutterAngle", shutterAngle); put("lens", lensModel); put("focalLength", focalLength)
        put("aperture", aperture); put("tStop", tStop); put("focusDistance", focusDistance); put("tilt", cameraTilt); put("roll", cameraRoll)
        if let audioChannels { out["audioChannels"] = String(audioChannels) }
        if let audioSampleRate { out["audioSampleRate"] = String(audioSampleRate) }
        put("bwfTimecode", bwfTimecode); put("createDate", creationDate)
        for (k, v) in rawFields where !v.isEmpty { out[Self.rawPrefix + k] = v }
        return out
    }

    /// Ricostruisce il modello dalle chiavi del database (le chiavi sconosciute finiscono in `extraColumns`; `raw.*` in `rawFields`).
    public init(columns: [String: String], family: String? = nil) {
        self.init()
        self.family = family
        for (key, value) in columns {
            switch key {
            case "clipName": clipName = value
            case "reel": reel = value
            case "manufacturer": cameraMake = value
            case "camera": cameraModel = value
            case "cameraSerial": cameraSerial = value
            case "firmware": firmware = value
            case "codec": codec = value
            case "container": container = value
            case "resolution":
                let p = value.split(separator: "x").compactMap { Int($0) }
                if p.count == 2 { width = p[0]; height = p[1] } else { extraColumns[key] = value }
            case "frameRate": if let d = Double(value) { fps = d } else { extraColumns[key] = value }
            case "timecode": timecodeStart = value
            case "durationSeconds": if let d = Double(value) { duration = d } else { extraColumns[key] = value }
            case "frameCount": if let n = Int(value) { frameCount = n } else { extraColumns[key] = value }
            case "colorSpace": colorSpace = value
            case "gamma": gamma = value
            case "iso": iso = value
            case "whiteBalance": whiteBalance = value
            case "shutter": shutter = value
            case "shutterAngle": shutterAngle = value
            case "lens": lensModel = value
            case "focalLength": focalLength = value
            case "aperture": aperture = value
            case "tStop": tStop = value
            case "focusDistance": focusDistance = value
            case "tilt": cameraTilt = value
            case "roll": cameraRoll = value
            case "audioChannels": if let n = Int(value) { audioChannels = n } else { extraColumns[key] = value }
            case "audioSampleRate": if let n = Int(value) { audioSampleRate = n } else { extraColumns[key] = value }
            case "bwfTimecode": bwfTimecode = value
            case "createDate": creationDate = value
            default:
                if key.hasPrefix(Self.rawPrefix) { rawFields[String(key.dropFirst(Self.rawPrefix.count))] = value } else { extraColumns[key] = value }
            }
        }
        status = hasValues ? .read : .unsupported
    }

    static func trimmed(_ v: Double, decimals: Int) -> String {
        var s = String(format: "%.\(decimals)f", v)
        while s.contains(".") && (s.hasSuffix("0") || s.hasSuffix(".")) { s.removeLast() }
        return s
    }
}
