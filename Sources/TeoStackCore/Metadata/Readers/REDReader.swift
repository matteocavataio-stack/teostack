import Foundation

/// RED: REDCODE RAW (.r3d). I tag si leggono con ExifTool (se c'è: è la versione più completa, verificata su un file vero V-RAPTOR [X] 8K);
/// senza ExifTool l'intestazione si legge in modo nativo (`R3DParser`, verificato solo contro ExifTool su file sintetici).
/// NON letti (non stanno in modo leggibile nell'intestazione): durata, numero di fotogrammi, gamma/color space, shutter, look, e il significato dei tag
/// che ExifTool chiama «Red_0x…» (restano in `rawFields`; l'unico interpretato è il timecode iniziale, vedi `REDMetadataMapper`). Per il resto servono R3DSDK/REDline di RED
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
        var tags: [String: Any]?
        if file.hasExifTool {
            do {
                let all = try file.exifTags()
                if all.keys.contains(where: { $0.hasPrefix("Red:") }) { tags = all }
            } catch let e as MetadataError { diagnostics.append(e.asDiagnostic) } catch {}
        }
        if tags == nil {
            tags = R3DParser.parse(url: file.url)
            if tags != nil { diagnostics.removeAll() }     // la lettura nativa è riuscita: l'assenza di ExifTool non è un problema per questo file
        }
        guard let tags, !tags.isEmpty else { return .unsupported(diagnostics) }
        var m = REDMetadataMapper.map(tags)
        m.diagnostics = diagnostics
        return m
    }
}

public enum REDMetadataMapper {
    /// `tags`: chiavi «Red:Nome» (ExifTool o R3DParser).
    ///
    /// Significato dei tag dimostrato da un file vero (V-RAPTOR [X] 8K VV): `CameraType` = lettera della camera («A»), NON il modello;
    /// il modello è `Brain`; `ReelNumber` «008» + lettera = «A008» (come nel nome del file A008_B009_…); `Take` = numero del clip («009»);
    /// `LensModel` «unknown» = lente non comunicata; `OriginalFileName` non è il nome di questo file (nei file a segmenti indica il primo).
    /// Dei due timecode senza nome del file («Red_0x10ad» 01:05:29:06, «Red_0x10ae» 12:23:34:16) il timecode iniziale è «Red_0x10ae»
    /// (confermato dall'utente guardando Silverstack); «Red_0x10ad» resta in `rawFields`. Nei RED più vecchi vale `StartTimecode`.
    public static func map(_ tags: [String: Any]) -> ClipMetadata {
        let t = TagBag(tags: tags)
        var m = ClipMetadata()
        m.family = "RED"
        m.container = "R3D"
        m.cameraMake = "RED"        // il formato R3D è di RED: il costruttore non è un tag del file ma lo definisce il formato
        if let quality = ExifMapper.real(t.string("Red:Quality")) { m.codec = "REDCODE RAW (\(quality))" } else { m.codec = "REDCODE RAW" }
        let cameraType = ExifMapper.real(t.string("Red:CameraType"))
        let model = ExifMapper.real(t.string("Red:Model", "Red:Brain"))
        if let model { m.cameraModel = model }
        if let cameraType {
            if cameraType.count <= 2 { m.extraColumns["cameraIndex"] = cameraType } else if m.cameraModel == nil { m.cameraModel = cameraType }
        }
        if let reelNumber = ExifMapper.real(t.string("Red:ReelNumber")) {
            m.reel = (cameraType.map { $0.count == 1 && $0.first!.isLetter } ?? false) ? cameraType! + reelNumber : reelNumber
        }
        m.cameraSerial = ExifMapper.real(t.string("Red:SerialNumber"))
        m.firmware = ExifMapper.real(t.string("Red:FirmwareVersion"))
        if let w = t.int("Red:ImageWidth"), let h = t.int("Red:ImageHeight"), w > 0, h > 0 { m.width = w; m.height = h }
        if let fps = t.double("Red:FrameRate"), fps > 0 { m.fps = (fps * 1000).rounded() / 1000 }
        m.timecodeStart = ExifMapper.timecode(t.string("Red:StartTimecode")) ?? ExifMapper.timecode(t.string("Red:Red_0x10ae"))
        m.creationDate = TagBag.date(t.string("Red:DateTimeOriginal"))
            ?? TagBag.date([t.string("Red:DateCreated"), t.string("Red:TimeCreated")].compactMap { $0 }.joined(separator: " "))
        if let k = t.double("Red:ColorTemperature"), k > 0 { m.whiteBalance = "\(Int(k.rounded())) K" }
        if let iso = t.int("Red:ISO"), iso > 0 { m.iso = String(iso) }
        if let f = t.double("Red:FNumber"), f > 0 { m.aperture = TagBag.format(f, decimals: 1) }
        if let mm = t.double("Red:FocalLength"), mm > 0 { m.focalLength = "\(TagBag.format(mm, decimals: 1)) mm" }
        if let d = t.double("Red:FocusDistance"), d > 0 { m.focusDistance = String(format: "%.2f m", d) }
        m.lensModel = ExifMapper.real(t.string("Red:LensModel")) ?? ExifMapper.real(t.string("Red:LensMake"))
        if let take = ExifMapper.real(t.string("Red:Take")) { m.extraColumns["take"] = take }
        if let sensorFPS = t.double("Red:OriginalFrameRate"), sensorFPS > 0 { m.extraColumns["sensorFPS"] = TagBag.format((sensorFPS * 1000).rounded() / 1000) }
        m.rawFields = RawTags.fields(from: tags)
        m.status = m.hasValues ? .read : .unsupported
        return m
    }
}
