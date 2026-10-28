import Foundation

extension ClipMetadata {
    /// Riempie SOLO i campi ancora vuoti con quelli di `other` (i valori già presenti non si toccano).
    mutating func fillMissing(from other: ClipMetadata) {
        func fill<T>(_ kp: WritableKeyPath<ClipMetadata, T?>) { if self[keyPath: kp] == nil { self[keyPath: kp] = other[keyPath: kp] } }
        fill(\.clipName); fill(\.reel); fill(\.cameraMake); fill(\.cameraModel); fill(\.cameraSerial); fill(\.firmware)
        fill(\.codec); fill(\.container); fill(\.width); fill(\.height); fill(\.fps); fill(\.timecodeStart); fill(\.duration)
        fill(\.frameCount); fill(\.colorSpace); fill(\.gamma); fill(\.iso); fill(\.whiteBalance); fill(\.shutter); fill(\.shutterAngle)
        fill(\.lensModel); fill(\.focalLength); fill(\.aperture); fill(\.tStop); fill(\.focusDistance); fill(\.cameraTilt); fill(\.cameraRoll)
        fill(\.audioChannels); fill(\.audioSampleRate); fill(\.bwfTimecode); fill(\.creationDate)
        for (k, v) in other.extraColumns where extraColumns[k] == nil { extraColumns[k] = v }
        for (k, v) in other.rawFields where rawFields[k] == nil { rawFields[k] = v }
    }
}

/// Costruttori riconosciuti dal testo di «Make»/«Manufacturer» (minuscolo, contiene).
enum Vendor {
    static let known: [(family: String, needles: [String])] = [
        ("ARRI", ["arri"]), ("RED", ["red digital", "red.com"]), ("Sony", ["sony"]), ("Canon", ["canon"]),
        ("Panasonic", ["panasonic", "matsushita"]), ("Blackmagic", ["blackmagic"]), ("Kinefinity", ["kinefinity"]),
        ("Phantom", ["vision research", "phantom"]), ("GoPro", ["gopro"]), ("DJI", ["dji"]), ("Apple", ["apple"]),
        ("Nikon", ["nikon"]), ("Fujifilm", ["fujifilm", "fuji photo"]), ("Leica", ["leica"]), ("Hasselblad", ["hasselblad"]),
    ]

    /// Solo per instradare: il produttore del SOFTWARE/registratore che ha scritto il file (MXF «ApplicationSupplierName»).
    /// NON è la camera, quindi non si scrive mai come costruttore; serve a riconoscere una famiglia quando il file non dichiara altro.
    static func family(forSupplier supplier: String?) -> String? {
        guard let f = family(forMake: supplier), ["Sony", "Canon", "Panasonic", "Blackmagic", "ARRI", "RED"].contains(f) else { return nil }
        return f
    }

    static func family(forMake make: String?) -> String? {
        guard let make = make?.lowercased(), !make.isEmpty else { return nil }
        return known.first { $0.needles.contains { make.contains($0) } }?.family
    }
}

/// Campi comuni letti dai tag di ExifTool (`-json -G1 -n`): MXF (dizionario SMPTE), QuickTime/MP4, EXIF/TIFF/DNG/DPX, IPTC.
/// Ogni nome di tag usato qui esiste nelle tabelle di ExifTool (lo verifica un test): un tag assente dà un campo vuoto, mai un valore stimato.
enum ExifMapper {
    static let makeKeys = ["Make", "DeviceManufacturerName", "AppleProappsManufacturer"]   // (ApplicationSupplierName è il SOFTWARE, non la camera)
    static let modelKeys = ["Model", "DeviceModel", "PlatformModel", "AppleProappsModelname", "UniqueCameraModel"]
    static let serialKeys = ["BodySerialNumber", "SerialNumber", "InternalSerialNumber", "CameraSerialNumber", "DeviceSerialNumber", "PlatformSerialNumber"]
    static let firmwareKeys = ["FirmwareVersion"]
    static let reelKeys = ["ReelOrRollNumber", "ReelName"]
    static let lensKeys = ["LensModel", "LensID"]
    static let isoKeys = ["ISO", "ExposureIndex", "OrgSmpteRdd18CameraIsosensitivity", "AppleProappsExifExifExposureIndex"]
    static let focusKeys = ["FocusDistance", "SubjectDistance"]
    static let dateKeys = ["DateTimeOriginal", "CreateDate", "ClipCreationDateTime"]
    static let apertureKeys = ["FNumber", "AppleProappsExifExifFNumber"]
    /// Nomi generati da ExifTool al volo (chiavi QuickTime «Keys», XMP DJI…): non stanno nell'elenco `-listx`.
    static let dynamicKeys = ["AppleProappsManufacturer", "AppleProappsModelname", "OrgSmpteRdd18CameraIsosensitivity", "AppleProappsExifExifExposureIndex",
                              "AppleProappsExifExifFNumber", "OrgSmpteRdd18CameraShutterspeedAngle", "OrgSmpteRdd18CameraWhitebalance",
                              "OrgSmpteRdd18LensIrisfnumber", "WhiteBalanceCCT", "GimbalPitchDegree", "GimbalRollDegree", "SensorFPS"]
    static let otherKeys = ["LensSerialNumber", "LensMake", "FocalLength", "ExposureTime", "ShutterAngle", "ColorTemperature",
                            "ColorPrimaries", "CaptureGammaEquation", "StartTimecode", "TimeCodes", "FrameRate", "ImageSize", "Software",
                            "DisplayWidth", "DisplayHeight"]

    /// Valori segnaposto che alcune camere scrivono al posto di un dato che non hanno.
    static func real(_ s: String?) -> String? {
        guard let s else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["", "unknown", "n/a", "na", "none", "null", "-", "--", "0"].contains(t.lowercased()) ? nil : t
    }

    /// Primo numero di un testo come «194.40deg», «5400K», «F2.8» (con segno e decimali).
    static func leadingNumber(_ s: String?) -> Double? {
        guard let s, let r = s.range(of: #"[-+]?\d+(?:\.\d+)?"#, options: .regularExpression) else { return nil }
        return Double(s[r])
    }

    static func map(_ tags: [String: Any], mediaRate: Double? = nil) -> ClipMetadata {
        let t = TagBag(tags: tags)
        var m = ClipMetadata()
        m.cameraMake = real(t.string(makeKeys))
        m.cameraModel = real(t.string(modelKeys))
        m.cameraSerial = real(t.string(serialKeys))
        m.reel = real(t.string(reelKeys))
        m.lensModel = real(t.string(lensKeys))
        if let s = real(t.string("LensSerialNumber")) { m.extraColumns["lensSerial"] = s }
        // firmware: tag dedicato; «Software» solo se è un numero di versione (es. 10.00.08.40), non il nome di un programma
        m.firmware = real(t.string(firmwareKeys))
        if m.firmware == nil, let sw = real(t.string("Software")), sw.range(of: #"^\d+(\.\d+)+$"#, options: .regularExpression) != nil { m.firmware = sw }
        if let mm = number(tags, ["FocalLength"]), mm > 0 { m.focalLength = "\(TagBag.format(mm, decimals: 1)) mm" }
        if let f = number(tags, apertureKeys) ?? leadingNumber(t.string("OrgSmpteRdd18LensIrisfnumber")), f > 0 { m.aperture = TagBag.format(f, decimals: 1) }
        if let iso = number(tags, isoKeys), iso > 0 { m.iso = String(Int(iso.rounded())) }
        if let e = number(tags, ["ExposureTime"]), e > 0 { m.shutter = shutterText(e) }
        if let a = number(tags, ["ShutterAngle"]) ?? leadingNumber(t.string("OrgSmpteRdd18CameraShutterspeedAngle")), a > 0 { m.shutterAngle = "\(TagBag.format(a, decimals: 1))°" }
        if let k = number(tags, ["ColorTemperature", "WhiteBalanceCCT"]) ?? leadingNumber(t.string("OrgSmpteRdd18CameraWhitebalance")), k > 0 { m.whiteBalance = "\(Int(k.rounded())) K" }
        if let d = number(tags, focusKeys), d > 0, d < 1e6 { m.focusDistance = String(format: "%.2f m", d) }
        if let p = number(tags, ["GimbalPitchDegree"]) { m.cameraTilt = TagBag.format(p, decimals: 1) }
        if let r = number(tags, ["GimbalRollDegree"]) { m.cameraRoll = TagBag.format(r, decimals: 1) }
        if let f = number(tags, ["SensorFPS"]), f > 0 { m.extraColumns["sensorFPS"] = TagBag.format(f) }
        m.colorSpace = nonNumeric(t.string("ColorPrimaries"))
        m.gamma = nonNumeric(t.string("CaptureGammaEquation"))
        m.timecodeStart = ARRIMetadataParser.startTimecode(tags, fallbackRate: mediaRate) ?? dngTimecode(t.string("TimeCodes")) ?? timecodePattern(t.string("TimeCodes"))
        for key in dateKeys { if let d = TagBag.date(t.string(key)) { m.creationDate = d; break } }
        // dimensioni: «Display» (area attiva, MXF) se dichiarata, altrimenti la dimensione dell'immagine
        if let w = number(tags, ["DisplayWidth"]), let h = number(tags, ["DisplayHeight"]), w > 0, h > 0 {
            m.width = Int(w); m.height = Int(h)
        } else if let size = t.string("Composite:ImageSize") {
            let p = size.split(whereSeparator: { $0 == " " || $0 == "x" }).compactMap { Int($0) }
            if p.count == 2, p[0] > 0, p[1] > 0 { m.width = p[0]; m.height = p[1] }
        }
        if let r = number(tags, ["FrameRate"]), r >= 0.001, r < 1000 { m.fps = (r * 1000).rounded() / 1000 }   // (valori minuscoli = byte non impostati)
        m.rawFields = RawTags.fields(from: tags)
        return m
    }

    /// DNG/CinemaDNG «TimeCodes»: 8 byte SMPTE 12M in esadecimale BCD, byte 0 = fotogrammi, 1 = secondi, 2 = minuti, 3 = ore (flag nei bit alti).
    /// «18.48.14.08.00.00.00.00» → 08:14:48:18 (come il PrintConv di ExifTool). Drop-frame (bit 0x40 del primo byte) → separatore «;».
    static func dngTimecode(_ raw: String?) -> String? {
        guard let first = raw?.split(separator: " ").first else { return nil }
        let b = first.split(separator: ".").compactMap { Int($0, radix: 16) }
        guard b.count >= 4 else { return nil }
        func bcd(_ v: Int, _ mask: Int) -> Int? {
            let x = v & mask
            guard x >> 4 < 10, x & 0xF < 10 else { return nil }
            return (x >> 4) * 10 + (x & 0xF)
        }
        guard let f = bcd(b[0], 0x3F), let s = bcd(b[1], 0x7F), let m = bcd(b[2], 0x7F), let h = bcd(b[3], 0x3F),
              h < 24, m < 60, s < 60 else { return nil }
        return String(format: "%02d:%02d:%02d%@%02d", h, m, s, (b[0] & 0x40) != 0 ? ";" : ":", f)
    }

    /// Il primo valore numerico fra i nomi indicati (un tag con più valori, es. ISO, dà il primo).
    static func number(_ tags: [String: Any], _ names: [String]) -> Double? {
        let bag = TagBag(tags: tags)
        for name in names {
            if let d = bag.double(name) { return d }
            if let key = tags.keys.sorted().first(where: { $0 == name || $0.hasSuffix(":" + name) }), let array = tags[key] as? [Any],
               let first = array.first as? NSNumber { return first.doubleValue }
        }
        return nil
    }

    /// 0.02 → «1/50»; 2 → «2 s». Mai approssimazioni inventate: solo se 1/x è un intero vicino.
    static func shutterText(_ seconds: Double) -> String {
        if seconds >= 1 { return "\(TagBag.format(seconds, decimals: 1)) s" }
        let inv = 1 / seconds
        if abs(inv - inv.rounded()) < 0.01 * inv.rounded() { return "1/\(Int(inv.rounded()))" }
        return "\(TagBag.format(seconds, decimals: 4)) s"
    }

    private static func nonNumeric(_ s: String?) -> String? {
        guard let s, Double(s) == nil else { return nil }
        return s
    }

    /// «HH:MM:SS:FF» (anche con «;») oppure nil.
    static func timecode(_ s: String?) -> String? { timecodePattern(s) }

    private static func timecodePattern(_ s: String?) -> String? {
        guard let s, s.range(of: #"^\d{2}[:;]\d{2}[:;]\d{2}[:;]\d{2}$"#, options: .regularExpression) != nil else { return nil }
        return s
    }
}

/// Raccoglie, per un file, i dati di ffprobe (parte tecnica), ExifTool (camera/lente/impostazioni) e dei file XML accanto al clip.
enum CameraMediaEngine {
    /// Foto/RAW fissi: ffprobe darebbe una durata e un frame rate inventati dal demuxer di immagini, quindi non si usano.
    static var stillExtensions: Set<String> { MediaClassifier.stillExtensions }

    static func isStill(_ file: ClipFile) -> Bool {
        switch file.probe.kind {
        case .tiff, .jpeg, .dpx: return true
        default: return stillExtensions.contains(file.ext)
        }
    }

    /// ExifTool sui MPEG sbaglia (codec, audio): per quei contenitori non si usa. Per il resto serve solo per i dati della camera.
    static func usesExifTool(_ file: ClipFile) -> Bool {
        switch file.probe.kind {
        case .mpegProgram, .riffWave, .xml: return false
        default: return true
        }
    }

    struct Gathered {
        var metadata = ClipMetadata()
        var diagnostics: [MetadataDiagnostic] = []
        var exifTags: [String: Any] = [:]
        var sidecarFound = false
    }

    static func gather(_ file: ClipFile, sidecars: Bool = true) -> Gathered {
        var g = Gathered()
        let still = isStill(file)
        var base = ClipMetadata()
        if !still, file.hasFFprobe {
            do {
                let json = try file.ffprobeJSON()
                base = ClipMetadata(columns: FFprobeMetadataParser.parse(json))
                base.rawFields.merge(FFprobeMetadataParser.rawFields(json)) { a, _ in a }
            } catch let e as MetadataError { g.diagnostics.append(e.asDiagnostic) } catch {}
        }
        var exif = ClipMetadata()
        if usesExifTool(file), file.hasExifTool {
            do {
                g.exifTags = try file.exifTags()
                exif = ExifMapper.map(g.exifTags, mediaRate: base.fps)
            } catch let e as MetadataError {
                // un formato che ExifTool non conosce non è un errore del file se altri lettori hanno dati
                g.diagnostics.append(e.asDiagnostic)
            } catch {}
        }
        // ffprobe prevale sui dati tecnici; ExifTool completa; per le foto il dimensionamento viene da ExifTool
        var merged = base
        merged.fillMissing(from: exif)
        if sidecars {
            for url in SidecarXML.siblings(of: file.url) {
                guard let flat = SidecarXML.read(url) else { continue }
                g.sidecarFound = true
                merged.fillMissing(from: SidecarMapper.map(flat))
            }
        }
        merged.container = merged.container ?? containerName(file)
        if merged.codec == nil, file.ext == "dng" || (merged.container == "DNG") {
            // CinemaDNG = DNG con i tag di timecode/frame rate del formato cinema
            merged.codec = (g.exifTags.keys.contains { $0.hasSuffix(":TimeCodes") || $0.hasSuffix(":FrameRate") }) ? "CinemaDNG" : "DNG"
        }
        g.metadata = merged
        return g
    }

    static func containerName(_ file: ClipFile) -> String? {
        switch file.probe.kind {
        case .mxf: return "MXF"
        case .riffWave: return "WAV"
        case .isoBMFF(let brand):
            switch file.ext {
            case "mp4", "m4v": return "MP4"
            case "mov": return "QuickTime"
            case "braw": return "BRAW"
            case "crm": return "Canon Cinema RAW Light"
            default: return brand.isEmpty ? "QuickTime" : "ISO-BMFF (\(brand.trimmingCharacters(in: .whitespaces)))"
            }
        case .mpegTransport: return ["mts", "m2ts"].contains(file.ext) ? "AVCHD/MPEG-TS" : "MPEG-TS"
        case .mpegProgram: return "MPEG-PS"
        case .tiff: return file.ext == "dng" ? "DNG" : "TIFF"
        case .jpeg: return "JPEG"
        case .dpx: return "DPX"
        case .r3d: return "R3D"
        case .cine: return "Cine"
        case .arriRaw: return "ARRIRAW"
        default: return nil
        }
    }
}

/// Famiglia di costruttore letta con ffprobe + ExifTool + sidecar XML. Si riconosce dal costruttore dichiarato nel file
/// (o dall'estensione, se è esclusiva della famiglia): altrimenti dà `.unsupported` e il registry passa oltre.
public struct CameraFamilyReader: MetadataReader {
    public let family: String
    public let extensions: Set<String>
    /// Estensioni che identificano la famiglia anche senza un «Make» nel file.
    let exclusiveExtensions: Set<String>
    /// Identificazione di un RAW proprietario quando nessuno strumento ne legge il contenuto: (container, codec).
    let identity: (container: String, codec: String)?
    let acceptedKinds: [ContainerKind]
    /// Dati specifici della famiglia (es. flusso «djmd» dei DJI), letti dopo quelli comuni. Riempiono solo i campi ancora vuoti.
    let enrich: ((ClipFile, inout ClipMetadata) -> Void)?

    public init(family: String, extensions: Set<String>, exclusiveExtensions: Set<String> = [], identity: (container: String, codec: String)? = nil,
                acceptedKinds: [ContainerKind]? = nil, enrich: ((ClipFile, inout ClipMetadata) -> Void)? = nil) {
        self.enrich = enrich
        self.family = family
        self.extensions = extensions
        self.exclusiveExtensions = exclusiveExtensions
        self.identity = identity
        self.acceptedKinds = acceptedKinds ?? CameraFamilyReader.defaultKinds
    }

    static let defaultKinds: [ContainerKind] = [.mxf, .mpegTransport, .tiff, .dpx, .jpeg, .unknown]

    public func canRead(_ file: ClipFile) -> Bool {
        guard extensions.contains(file.ext) else { return false }
        if case .isoBMFF = file.probe.kind { return true }
        return acceptedKinds.contains(file.probe.kind)
    }

    public func read(_ file: ClipFile) -> ClipMetadata {
        let g = CameraMediaEngine.gather(file)
        var m = g.metadata
        let declared = Vendor.family(forMake: m.cameraMake)
        let hint = Vendor.family(forSupplier: TagBag(tags: g.exifTags).string("ApplicationSupplierName"))
        let mine = declared == family || (declared == nil && (hint == family || exclusiveExtensions.contains(file.ext)))
        guard mine else { return .unsupported(g.diagnostics) }
        enrich?(file, &m)
        if let identity {
            m.container = m.container ?? identity.container
            if m.codec == nil { m.codec = identity.codec }
        }
        m.family = family
        m.diagnostics = g.diagnostics
        m.status = m.hasValues ? .read : .unsupported
        if m.status == .read, !m.hasContentBeyondIdentity { m.status = .partial }
        return m
    }
}

extension ClipMetadata {
    /// Più dei soli dati di identità del formato (contenitore/codec dedotti dall'estensione).
    var hasContentBeyondIdentity: Bool {
        columns.keys.contains { !["container", "codec"].contains($0) && !$0.hasPrefix(Self.rawPrefix) }
    }
}

/// Qualsiasi altro file con metadata leggibili (GoPro, DSLR, iPhone, DJI, immagini, MXF/MOV senza costruttore riconosciuto…).
public struct GenericMediaReader: MetadataReader {
    public let family = "Generic"
    public let extensions: Set<String> = []
    public init() {}

    public func canRead(_ file: ClipFile) -> Bool {
        switch file.probe.kind {
        case .r3d, .cine, .arriRaw, .xml: return false
        default: return file.hasFFprobe || file.hasExifTool
        }
    }

    public func read(_ file: ClipFile) -> ClipMetadata {
        let g = CameraMediaEngine.gather(file)
        var m = g.metadata
        guard m.hasValues else { return .unsupported(g.diagnostics) }
        m.family = Vendor.family(forMake: m.cameraMake).map { "Generic (\($0))" } ?? family
        m.diagnostics = g.diagnostics
        m.status = .read
        return m
    }
}
