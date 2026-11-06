import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// File XML accanto al clip scritti dalla camera (Sony `C0001M01.XML`, Canon/Panasonic P2 `<clip>.XML`…). Sola lettura.
/// L'XML si «appiattisce» in chiavi `Elemento/Figlio@attributo` → valore: nessuna interpretazione dei nomi finché non serve a un campo noto.
public enum SidecarXML {
    /// XML che stanno nella stessa cartella e hanno il nome del clip (con o senza il suffisso `M01` di Sony). Maiuscole/minuscole ignorate.
    public static func siblings(of clip: URL) -> [URL] {
        let dir = clip.deletingLastPathComponent()
        let stem = clip.deletingPathExtension().lastPathComponent.lowercased()
        let wanted: Set<String> = [stem + ".xml", stem + "m01.xml"]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { wanted.contains($0.lowercased()) && !$0.hasPrefix(".") }.sorted().map { dir.appendingPathComponent($0) }
    }

    static let maxBytes = 2 * 1024 * 1024
    static let maxEntries = 600

    public static func read(_ url: URL) -> [String: String]? {
        guard let handle = try? FileHandle(forReadingFrom: url), let data = try? handle.read(upToCount: maxBytes), !data.isEmpty else { return nil }
        try? handle.close()
        return flatten(data)
    }

    public static func flatten(_ data: Data) -> [String: String]? {
        let parser = XMLParser(data: data)
        let delegate = Flattener()
        parser.delegate = delegate
        guard parser.parse(), !delegate.values.isEmpty else { return nil }
        return delegate.values
    }

    private final class Flattener: NSObject, XMLParserDelegate {
        var values: [String: String] = [:]
        private var stack: [String] = []
        private var groupNames: [String?] = []
        private var text = ""
        private var counts: [String: Int] = [:]

        private func local(_ name: String) -> String { name.split(separator: ":").last.map(String.init) ?? name }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            stack.append(local(name))
            groupNames.append(local(name) == "Group" ? attributes["name"] : nil)
            // «<Item name="ISOSensitivity" value="800"/>» dentro «<Group name="CameraUnitMetadataSet">» → chiave «Item:CameraUnitMetadataSet/ISOSensitivity»
            if local(name) == "Item", let item = attributes["name"], let value = attributes["value"], values.count < SidecarXML.maxEntries {
                let group = groupNames.dropLast().reversed().compactMap { $0 }.first ?? "-"
                let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty, t.count <= 500 { values["Item:\(group)/\(item)"] = t }
            }
            text = ""
            let path = stack.joined(separator: "/")
            let n = (counts[path] ?? 0) + 1
            counts[path] = n
            let key = n == 1 ? path : "\(path)[\(n)]"
            for (k, v) in attributes where values.count < SidecarXML.maxEntries {
                let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty, t.count <= 500 { values["\(key)@\(local(k))"] = t }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, t.count <= 500, values.count < SidecarXML.maxEntries {
                let path = stack.joined(separator: "/")
                let n = counts[path] ?? 1
                values[n == 1 ? path : "\(path)[\(n)]"] = t
            }
            text = ""
            _ = stack.popLast()
            _ = groupNames.popLast()
        }
    }
}

/// Campi noti da un sidecar appiattito. Si usa solo ciò che il file dichiara con quel nome; tutto il resto resta in `rawFields` («sidecar:…»).
enum SidecarMapper {
    static func map(_ flat: [String: String]) -> ClipMetadata {
        var m = ClipMetadata()
        func attr(_ element: String, _ name: String) -> String? {
            for key in flat.keys.sorted() {
                let parts = key.split(separator: "@", maxSplits: 1).map(String.init)
                guard parts.count == 2, parts[1] == name else { continue }
                if parts[0].split(separator: "/").last.map({ String($0).split(separator: "[").first.map(String.init) == element }) == true { return flat[key] }
            }
            return nil
        }
        func text(_ element: String) -> String? {
            for key in flat.keys.sorted() where !key.contains("@") {
                if key.split(separator: "/").last.map({ String($0).split(separator: "[").first.map(String.init) == element }) == true { return flat[key] }
            }
            return nil
        }
        // Sony: «Camera» = la camera (es. MPC-3610), «Device» = il registratore (es. AXS-R7). Senza «Camera» (XAVC, FX3…) il «Device» è la camera.
        if let cameraModel = ExifMapper.real(attr("Camera", "modelName")) {
            m.cameraMake = ExifMapper.real(attr("Camera", "manufacturer"))
            m.cameraModel = sonyCameraNames[cameraModel] ?? cameraModel
            m.cameraSerial = ExifMapper.real(attr("Camera", "serialNo"))
            m.firmware = ExifMapper.real(flat["NonRealTimeMeta/Camera/Element@software"])
            if let recorder = ExifMapper.real(attr("Device", "modelName")) { m.extraColumns["recorder"] = recorder }
        } else {
            m.cameraMake = attr("Device", "manufacturer") ?? text("Manufacturer")
            m.cameraModel = attr("Device", "modelName") ?? text("ModelName")
            m.cameraSerial = attr("Device", "serialNo") ?? text("SerialNo") ?? text("SerialNumber")
        }
        // «<Lens manufacturer="" modelName="Supreme Prime 29/T1.5        "/>»: il nome della lente come lo scrive la camera (senza spazi in coda)
        m.lensModel = ExifMapper.real(attr("Lens", "modelName"))
        m.creationDate = TagBag.date(attr("CreationDate", "value") ?? text("CreationDate"))
        if let codec = attr("VideoFrame", "videoCodec") { m.codec = codecName(codec) }
        if let capture = attr("VideoFrame", "captureFps") {
            let digits = capture.filter { $0.isNumber || $0 == "." }
            if let v = Double(digits), v > 0 { m.extraColumns["sensorFPS"] = TagBag.format(v) }
        }
        if let w = attr("VideoLayout", "pixel").flatMap(Int.init), let h = attr("VideoLayout", "numOfVerticalLine").flatMap(Int.init), w > 0, h > 0 {
            m.width = w; m.height = h
        }
        // «<Duration value="252"/>»: numero di fotogrammi (come lo leggono ffmpeg e telemetry-parser)
        if let frames = attr("Duration", "value").flatMap(Int.init), frames > 0 { m.frameCount = frames }
        // Voci di acquisizione («Item» con nome e valore). Nomi e unità verificati su un XML vero di VENICE (MPC-3610 + AXS-R7) e sullo schema EBU Tech 3349.
        func item(_ names: String...) -> String? {
            for name in names {
                for key in flat.keys.sorted() where key.hasPrefix("Item:") && key.lowercased().hasSuffix("/" + name.lowercased()) { return flat[key] }
            }
            return nil
        }
        if let iso = ExifMapper.leadingNumber(item("ISOSensitivity", "ExposureIndexOfPhotoMeter")), iso > 0 { m.iso = String(Int(iso.rounded())) }
        if let k = ExifMapper.leadingNumber(item("WhiteBalance")), k > 0 { m.whiteBalance = "\(Int(k.rounded())) K" }
        // Angolo dello shutter: in 1/60 di grado (EBU Tech 3349: 21600 = 360°; VENICE scrive 10800 per 180°). Il tempo (1/48…) si deriva dal frame rate di ripresa.
        if let raw = ExifMapper.leadingNumber(item("ShutterSpeedAngle", "ShutterSpeed_Angle")), raw > 0 {
            let angle = raw / 60
            m.shutterAngle = "\(TagBag.format(angle, decimals: 1))°"
            if let fps = m.extraColumns["sensorFPS"].flatMap(Double.init), fps > 0 {
                let text = ExifMapper.shutterText(angle / 360 / fps)
                if text.hasPrefix("1/") { m.shutter = text }
            }
        }
        if let f = ExifMapper.leadingNumber(item("IrisFNumber")), f > 0 { m.aperture = TagBag.format(f, decimals: 1) }
        if let nd = ndFilter(item("NeutralDensityFilterWheelSetting")) { m.extraColumns["ndFilter"] = nd }
        if let look = lookInfo(flat) { m.extraColumns["lookInfo"] = look }
        m.gamma = ExifMapper.real(item("CaptureGammaEquation"))
        m.colorSpace = ExifMapper.real(item("CaptureColorPrimaries"))
        // «UserDescriptiveMetadata»: Meta name="Scene" content="12": solo i campi compilati
        let meta = userMeta(flat)
        if let c = meta["CameraIndex"] { m.extraColumns["cameraIndex"] = c }
        if let r = meta["Reel"] { m.reel = (meta["CameraIndex"] ?? "") + r }
        if let v = meta["Scene"] { m.extraColumns["scene"] = v }
        if let v = meta["Take"] { m.extraColumns["take"] = v }
        for (k, v) in flat { m.rawFields["sidecar:" + k] = v }
        m.status = m.hasValues ? .read : .unsupported
        return m
    }

    /// Filtro ND: «NeutralDensityFilterWheelSetting» è il reciproco del rapporto di attenuazione (1 = «clear», 4 = 2 stop = ND 0.6, 8 = ND 0.9…; EBU Tech 3349).
    static func ndFilter(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        guard let n = Double(raw), n >= 1 else { return raw }       // valore non previsto dallo schema: così come dichiarato
        if n == 1 { return "Clear" }
        return "ND \(TagBag.format(log10(n), decimals: 1))"
    }

    /// Look applicato in ripresa: la trasformazione prima del CDL (es. «LUT:SL3SG3tos709.cube» → «SL3SG3tos709.cube»); «(baked)» se è impresso nell'immagine.
    static func lookInfo(_ flat: [String: String]) -> String? {
        func value(_ name: String) -> String? {
            for key in flat.keys.sorted() where key.hasPrefix("Item:") && key.hasSuffix("/" + name) {
                let t = flat[key]?.trimmingCharacters(in: .whitespaces) ?? ""
                return ["", "none", "unknown"].contains(t.lowercased()) ? nil : t
            }
            return nil
        }
        guard var look = value("PreCDLTransform") else { return nil }
        if look.lowercased().hasPrefix("lut:") { look = String(look.dropFirst(4)) }
        if look.isEmpty { return nil }
        if value("LookProcessBaked")?.lowercased() == "true" { look += " (baked)" }
        return look
    }

    /// «<Meta name="Scene" content="12"/>» → ["Scene": "12"] (voci vuote escluse).
    static func userMeta(_ flat: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        let prefix = "NonRealTimeMeta/UserDescriptiveMetadata/Meta"
        for (key, name) in flat where key.hasPrefix(prefix) && key.hasSuffix("@name") {
            let base = String(key.dropLast("@name".count))
            if let content = flat[base + "@content"]?.trimmingCharacters(in: .whitespaces), !content.isEmpty { out[name] = content }
        }
        return out
    }

    /// Nome commerciale dei modelli Sony dal codice che la camera scrive nell'XML (il codice resta in `rawFields`). Solo codici confermati.
    static let sonyCameraNames: [String: String] = ["MPC-3610": "VENICE 1"]

    /// «F55_X-OCN_XT_6K_17:9» (etichetta interna Sony della famiglia F55/VENICE) → «X-OCN XT 6K 17:9»: il prefisso «F55_» non è la camera.
    static func codecName(_ declared: String) -> String {
        guard declared.hasPrefix("F55_") else { return declared }
        return String(declared.dropFirst(4)).replacingOccurrences(of: "_", with: " ")
    }
}
