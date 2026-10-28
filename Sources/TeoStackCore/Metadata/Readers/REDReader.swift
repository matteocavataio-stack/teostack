import Foundation

/// RED: REDCODE RAW (.r3d). L'intestazione si legge in modo nativo (`R3DParser`, nessun programma esterno); se non riesce si usa ExifTool.
/// NON letti (non stanno nell'intestazione): durata, numero di fotogrammi, gamma/color space, shutter, look. Per questi serve R3DSDK/REDline di RED
/// (SDK non incluso: la licenza RED richiede registrazione e accettazione del contratto, non scaricabile in automatico).
public struct REDReader: MetadataReader {
    public let family = "RED"
    public let extensions: Set<String> = ["r3d"]
    public init() {}

    public func canRead(_ file: ClipFile) -> Bool {
        file.probe.kind == .r3d || (file.ext == "r3d" && file.probe.kind == .unknown)
    }

    public func read(_ file: ClipFile) -> ClipMetadata {
        var diagnostics: [MetadataDiagnostic] = []
        var tags = R3DParser.parse(url: file.url)
        if tags == nil, file.hasExifTool {
            do { tags = try file.exifTags() } catch let e as MetadataError { diagnostics.append(e.asDiagnostic) } catch {}
        }
        guard let tags, !tags.isEmpty else { return .unsupported(diagnostics) }
        var m = REDMetadataMapper.map(tags)
        m.diagnostics = diagnostics
        return m
    }
}

public enum REDMetadataMapper {
    /// `tags`: chiavi «Red:Nome» (R3DParser o ExifTool).
    public static func map(_ tags: [String: Any]) -> ClipMetadata {
        let t = TagBag(tags: tags)
        var m = ClipMetadata()
        m.family = "RED"
        m.container = "R3D"
        m.codec = "REDCODE RAW"
        m.cameraMake = "RED"        // il formato R3D è di RED: il costruttore non è un tag del file ma lo definisce il formato
        m.clipName = t.string("Red:OriginalFileName")
        m.reel = t.string("Red:ReelNumber")
        m.cameraModel = t.string("Red:Model", "Red:CameraType")
        m.cameraSerial = t.string("Red:SerialNumber")
        m.firmware = t.string("Red:FirmwareVersion")
        if let w = t.int("Red:ImageWidth"), let h = t.int("Red:ImageHeight"), w > 0, h > 0 { m.width = w; m.height = h }
        if let fps = t.double("Red:FrameRate"), fps > 0 { m.fps = (fps * 1000).rounded() / 1000 }
        m.timecodeStart = t.string("Red:StartTimecode")
        m.creationDate = TagBag.date(t.string("Red:DateTimeOriginal"))
            ?? TagBag.date([t.string("Red:DateCreated"), t.string("Red:TimeCreated")].compactMap { $0 }.joined(separator: " "))
        if let k = t.double("Red:ColorTemperature"), k > 0 { m.whiteBalance = "\(Int(k.rounded())) K" }
        if let iso = t.int("Red:ISO"), iso > 0 { m.iso = String(iso) }
        if let f = t.double("Red:FNumber"), f > 0 { m.aperture = TagBag.format(f, decimals: 1) }
        if let mm = t.double("Red:FocalLength"), mm > 0 { m.focalLength = "\(TagBag.format(mm, decimals: 1)) mm" }
        if let d = t.double("Red:FocusDistance"), d > 0 { m.focusDistance = String(format: "%.2f m", d) }
        m.lensModel = t.string("Red:LensModel") ?? t.string("Red:LensMake")
        if let take = t.string("Red:Take") { m.extraColumns["take"] = take }
        if let sensorFPS = t.double("Red:OriginalFrameRate"), sensorFPS > 0 { m.extraColumns["sensorFPS"] = TagBag.format((sensorFPS * 1000).rounded() / 1000) }
        m.rawFields = RawTags.fields(from: tags)
        m.status = m.hasValues ? .read : .unsupported
        return m
    }
}
