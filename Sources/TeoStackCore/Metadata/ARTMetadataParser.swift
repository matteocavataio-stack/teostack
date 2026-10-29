import Foundation

/// Parser per l'export JSON di `art-cmd` (ARRI Reference Tool CMD 1.0.0): `art-cmd export --input clip.mxf --duration 1 --output metadata.json`.
///
/// Struttura verificata su un clip MXF/ARRIRAW di una ALEXA 35 (fixture nei test) e unità di misura verificate negli schemi JSON
/// pubblicati da ARRI (https://www.arri.com/schema/json/camera/...):
/// - exposureIndex: ISO lineare · exposureTime: secondi ("1/50") · sensorSampleRate: fps
/// - ndFilterDensity: densità ottica · colorTemperature: K · whiteBalanceTint: correzione verde/magenta
/// - lensFocalLength: µm (0 = non disponibile)
///
/// I valori "dinamici" (ISO, lente, ND, WB, shutter, timecode, sensor FPS) sono quelli del PRIMO fotogramma del clip:
/// su uno zoom o un ND variabile possono cambiare durante la ripresa.
/// Un campo assente o "non disponibile" resta assente (→ N/D): non viene mai inventato.
public enum ARTMetadataParser {
    public static func canParse(_ json: [String: Any]) -> Bool {
        json["arriJsonHeader"] != nil && (json["clipBasedMetadataSets"] != nil || json["descriptiveMetadataSets"] != nil)
    }

    public static func parse(_ json: [String: Any]) -> [String: String] {
        guard canParse(json) else { return [:] }
        var out: [String: String] = [:]

        let camera = payload(json, "descriptiveMetadataSets", "Camera Device")
        if let v = string(camera["cameraModel"]) { out["camera"] = v; out["manufacturer"] = "ARRI" }   // art-cmd legge solo clip ARRI
        if let v = string(camera["cameraSerialNumber"]) { out["cameraSerial"] = v }
        if let v = string(camera["cameraSoftwarePackageName"]) { out["firmware"] = v }

        let clipInfo = payload(json, "clipBasedMetadataSets", "Clip Info")
        if let v = string(clipInfo["videoCodec"]) { out["codec"] = v }

        let size = payload(json, "clipBasedMetadataSets", "Image Size")
        if let stored = size["storedSize"] as? [String: Any], let w = number(stored["width"]), let h = number(stored["height"]) {
            out["resolution"] = "\(Int(w))x\(Int(h))"
        }

        let audio = payload(json, "clipBasedMetadataSets", "Audio")
        if let v = string(audio["audioCodec"]) { out["audioCodec"] = v }
        if let v = number(audio["audioChannels"]) { out["audioChannels"] = String(Int(v)) }
        if let v = number(audio["audioSampleRate"]) { out["audioSampleRate"] = String(Int(v)) }
        if let v = number(audio["audioBitDepth"]) { out["audioBitDepth"] = String(Int(v)) }

        let color = payload(json, "clipBasedMetadataSets", "Color")
        if let look = color["lookInfo"] as? [String: Any], let name = string(look["lookFilename"]) { out["lookInfo"] = name }
        if let enc = color["sceneColorEncoding"] as? [String: Any],
           let p = string(enc["sceneColorEncodingPrimaries"]), let t = string(enc["sceneColorEncodingTransferCurve"]) {
            out["colorSpace"] = "\(p) / \(t)"
        }

        let lens = payload(json, "descriptiveMetadataSets", "Lens Device")
        if let v = string(lens["lensModel"]) { out["lens"] = v }
        if let v = string(lens["lensSerialNumber"]) { out["lensSerial"] = v }

        let slate = payload(json, "descriptiveMetadataSets", "Slate Info")
        if let v = string(slate["reelName"]) { out["reel"] = v }
        if let v = string(slate["cameraIndex"]) { out["cameraIndex"] = v }
        if let v = string(slate["scene"]) { out["scene"] = v }
        if let v = string(slate["take"]) { out["take"] = v }
        if let v = string(slate["production"]) { out["production"] = v }
        if let v = string(slate["productionCompany"]) { out["productionCompany"] = v }
        if let v = string(slate["director"]) { out["director"] = v }
        if let v = string(slate["cinematographer"]) { out["cinematographer"] = v }
        if let v = string(slate["location"]) { out["location"] = v }

        // Primo fotogramma
        if let frameBased = json["frameBasedMetadata"] as? [String: Any],
           let frames = frameBased["frames"] as? [[String: Any]], let first = frames.first {
            if let tc = string(first["timecode"]) { out["timecode"] = tc }
            let sets = first["frameBasedMetadataSets"] as? [String: Any] ?? [:]

            if let s = sets["Sensor State"] as? [String: Any] {
                if let iso = number(s["exposureIndex"]) { out["iso"] = String(Int(iso)) }
                let sensorFPS = rational(s["sensorSampleRate"])
                if let r = sensorFPS { out["sensorFPS"] = trimmed(r, decimals: 3) }
                // tempo di esposizione: «1/50», «0.02» o un numero → in secondi; l'angolo dello shutter si ricava da tempo e frame rate del sensore
                // (angolo = 360° × tempo × fps; es. 1/50 s a 24 fps = 172,8°): è un calcolo su due valori del file, non un valore letto
                if let seconds = exposureSeconds(s["exposureTime"]), seconds > 0 {
                    out["shutter"] = ExifMapper.shutterText(seconds)
                    if let fps = sensorFPS, fps > 0 { out["shutterAngle"] = "\(trimmed(360 * seconds * fps, decimals: 1))°" }
                } else if let t = string(s["exposureTime"]) { out["shutter"] = t }
            }
            if let f = sets["Filter"] as? [String: Any], let d = number(f["ndFilterDensity"]) {
                out["ndFilter"] = "ND \(trimmed(d, decimals: 1))"
            }
            if let w = sets["White Balance"] as? [String: Any], let k = number(w["colorTemperature"]) {
                var text = "\(Int(k)) K"
                if let tint = number(w["whiteBalanceTint"]), abs(tint) > 0.0001 { text += String(format: ", tint %+.1f", tint) }
                out["whiteBalance"] = text
                if let tint = number(w["whiteBalanceTint"]) { out["tint"] = trimmed(tint, decimals: 1) }
            }
            if let positional = sets["Positional"] as? [String: Any], let o = positional["orientation"] as? [String: Any] {
                if let tilt = number(o["tilt"]) { out["tilt"] = trimmed(tilt, decimals: 1) }
                if let roll = number(o["roll"]) { out["roll"] = trimmed(roll, decimals: 1) }
            }
            if let l = sets["Lens State"] as? [String: Any], let um = number(l["lensFocalLength"]), um > 0 {
                out["focalLength"] = String(format: "%.0f mm", um / 1000)
            }
            // distanza di messa a fuoco: lensFocusDistanceMetric è in mm; 0 = non disponibile, -1 = infinito (schema ARRI)
            if let l = sets["Lens State"] as? [String: Any], let mm = number(l["lensFocusDistanceMetric"]), mm > 0 {
                out["focusDistance"] = String(format: "%.2f m", mm / 1000)
            }
        }
        return out
    }

    // MARK: Accesso

    private static func payload(_ json: [String: Any], _ group: String, _ name: String) -> [String: Any] {
        guard let sets = json[group] as? [[String: Any]],
              let set = sets.first(where: { ($0["metadataSetName"] as? String) == name }),
              let payload = set["metadataSetPayload"] as? [String: Any] else { return [:] }
        return payload
    }

    private static func string(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber, !n.isJSONBoolean { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    /// «1/50» → 0,02 · «0.02» → 0,02 · 0,02 → 0,02.
    static func exposureSeconds(_ value: Any?) -> Double? {
        if let s = value as? String {
            let parts = s.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d != 0 { return n / d }
            return Double(s.trimmingCharacters(in: .whitespaces))
        }
        return number(value)
    }

    /// "24/1" → 24 · "24000/1001" → 23.976...
    private static func rational(_ value: Any?) -> Double? {
        guard let s = value as? String else { return number(value) }
        let parts = s.split(separator: "/").map(String.init)
        if parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d != 0 { return n / d }
        return Double(s)
    }

    private static func trimmed(_ v: Double, decimals: Int) -> String {
        var s = String(format: "%.\(decimals)f", v)
        while s.contains(".") && (s.hasSuffix("0") || s.hasSuffix(".")) { s.removeLast() }
        return s
    }
}
