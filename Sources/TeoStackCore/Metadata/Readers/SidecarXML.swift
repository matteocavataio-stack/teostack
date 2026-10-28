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
        m.cameraMake = attr("Device", "manufacturer") ?? text("Manufacturer")
        m.cameraModel = attr("Device", "modelName") ?? text("ModelName")
        m.cameraSerial = attr("Device", "serialNo") ?? text("SerialNo") ?? text("SerialNumber")
        m.creationDate = TagBag.date(attr("CreationDate", "value") ?? text("CreationDate"))
        if let codec = attr("VideoFrame", "videoCodec") { m.codec = codec }
        if let capture = attr("VideoFrame", "captureFps") {
            let digits = capture.filter { $0.isNumber || $0 == "." }
            if let v = Double(digits), v > 0 { m.extraColumns["sensorFPS"] = TagBag.format(v) }
        }
        if let w = attr("VideoLayout", "pixel").flatMap(Int.init), let h = attr("VideoLayout", "numOfVerticalLine").flatMap(Int.init), w > 0, h > 0 {
            m.width = w; m.height = h
        }
        // «<Duration value="252"/>»: numero di fotogrammi (come lo leggono ffmpeg e telemetry-parser)
        if let frames = attr("Duration", "value").flatMap(Int.init), frames > 0 { m.frameCount = frames }
        // Voci di acquisizione («Item» con nome e valore): solo i nomi del dizionario SMPTE RDD 18 che si ritrovano anche nei MOV (isosensitivity, whitebalance,
        // shutterspeed_angle, irisfnumber). NON verificato su un XML vero di VENICE: i nomi esatti dipendono dal modello.
        func item(_ name: String) -> String? {
            for key in flat.keys.sorted() where key.hasPrefix("Item:") && key.lowercased().hasSuffix("/" + name.lowercased()) { return flat[key] }
            return nil
        }
        if let iso = ExifMapper.leadingNumber(item("ISOSensitivity")), iso > 0 { m.iso = String(Int(iso.rounded())) }
        if let k = ExifMapper.leadingNumber(item("WhiteBalance")), k > 0 { m.whiteBalance = "\(Int(k.rounded())) K" }
        if let a = ExifMapper.leadingNumber(item("ShutterSpeed_Angle")), a > 0 { m.shutterAngle = "\(TagBag.format(a, decimals: 1))°" }
        if let f = ExifMapper.leadingNumber(item("IrisFNumber")), f > 0 { m.aperture = TagBag.format(f, decimals: 1) }
        m.gamma = ExifMapper.real(item("CaptureGammaEquation"))
        m.colorSpace = ExifMapper.real(item("CaptureColorPrimaries"))
        for (k, v) in flat { m.rawFields["sidecar:" + k] = v }
        m.status = m.hasValues ? .read : .unsupported
        return m
    }
}
