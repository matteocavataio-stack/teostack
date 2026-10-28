import Foundation

/// Metadata dei formati senza parser dedicato, a partire dal JSON di ffprobe.
///
/// Si scrive SOLO ciò che il file dichiara: un valore assente resta assente (→ N/D), nessuna stima.
/// Campi: codec, risoluzione, frame rate, durata, data di creazione, timecode (quello scritto nel file), camera/costruttore se il file li ha,
/// e i dati audio (codec, tracce, frequenza di campionamento, bit).
public enum FFprobeMetadataParser {
    public static func parse(_ json: [String: Any]) -> [String: String] {
        let streams = (json["streams"] as? [[String: Any]]) ?? []
        let format = (json["format"] as? [String: Any]) ?? [:]
        let formatTags = tags(format)
        let video = streams.first { type($0) == "video" && !isAttachedPicture($0) }
        let audio = streams.filter { type($0) == "audio" }
        var out: [String: String] = [:]

        if let video {
            if let label = videoCodecLabel(video) { out["codec"] = label }
            if let w = number(video["width"]), let h = number(video["height"]), w > 0, h > 0 { out["resolution"] = "\(Int(w))x\(Int(h))" }
            if let fps = frameRate(video) { out["frameRate"] = trimmed(fps, decimals: 3) }
        }

        if let d = number(format["duration"]) ?? number(video?["duration"]) ?? number(audio.first?["duration"]), d > 0 {
            out["durationSeconds"] = trimmed(d, decimals: 3)
        }

        // audio
        if !audio.isEmpty {
            let codecs = unique(audio.compactMap(audioCodecLabel))
            if !codecs.isEmpty { out["audioCodec"] = codecs.joined(separator: ", ") }
            let channels = audio.compactMap { number($0["channels"]) }.reduce(0, +)
            if channels > 0 { out["audioChannels"] = String(Int(channels)) }
            let rates = unique(audio.compactMap { number($0["sample_rate"]) }.filter { $0 > 0 }.map { String(Int($0)) })
            if !rates.isEmpty { out["audioSampleRate"] = rates.joined(separator: ", ") }
            let depths = unique(audio.compactMap(bitDepth).map { String($0) })
            if !depths.isEmpty { out["audioBitDepth"] = depths.joined(separator: ", ") }
        }

        // dati scritti dalla camera/registratore, solo se presenti
        let allTags = [formatTags] + streams.map { tags($0) }
        if let v = firstTag(allTags, ["com.apple.quicktime.make", "make"]) { out["manufacturer"] = v }
        if let v = firstTag(allTags, ["com.apple.quicktime.model", "model"]) { out["camera"] = v }

        if let created = createDate(formatTags: formatTags, streamTags: streams.map { tags($0) }) { out["createDate"] = created }

        if let tc = firstTag(allTags, ["timecode"]), isTimecode(tc) {
            out["timecode"] = tc
        } else if video == nil, let tc = broadcastWaveTimeReference(formatTags: formatTags, sampleRate: number(audio.first?["sample_rate"])) {
            out["timecode"] = tc
        }
        return out
    }

    // MARK: Codec

    private static let videoNames: [String: String] = [
        "mpeg2video": "MPEG-2", "mpeg1video": "MPEG-1", "h264": "H.264", "hevc": "H.265 (HEVC)", "prores": "ProRes",
        "dnxhd": "DNxHD/DNxHR", "mjpeg": "Motion JPEG", "mpeg4": "MPEG-4", "av1": "AV1", "vp9": "VP9", "vp8": "VP8",
        "cfhd": "CineForm", "jpeg2000": "JPEG 2000", "dvvideo": "DV", "rawvideo": "Raw video",
    ]

    private static let audioNames: [String: String] = [
        "ac3": "AC-3", "eac3": "E-AC-3", "aac": "AAC", "mp2": "MP2", "mp3": "MP3", "flac": "FLAC", "alac": "ALAC",
        "opus": "Opus", "vorbis": "Vorbis", "dts": "DTS", "truehd": "TrueHD",
    ]

    /// FourCC di codec che ffprobe non decodifica (nessun `codec_name`) ma che il file dichiara: si usa il nome del formato, non una stima.
    static let fourCCNames: [String: String] = ["aprn": "Apple ProRes RAW", "aprh": "Apple ProRes RAW HQ", "braw": "Blackmagic RAW"]

    static func videoCodecLabel(_ stream: [String: Any]) -> String? {
        guard let name = string(stream["codec_name"]), name.lowercased() != "unknown" else {
            if let tag = string(stream["codec_tag_string"])?.lowercased(), let known = fourCCNames[tag] { return known }
            return nil
        }
        let base = videoNames[name] ?? string(stream["codec_long_name"]) ?? name
        if let profile = string(stream["profile"]), profile.lowercased() != "unknown" { return "\(base) \(profile)" }
        return base
    }

    static func audioCodecLabel(_ stream: [String: Any]) -> String? {
        guard let name = string(stream["codec_name"]) else { return nil }
        if name.hasPrefix("pcm_f") { return "PCM float" }
        if name.hasPrefix("pcm_s") || name.hasPrefix("pcm_u") { return "PCM" }
        let base = audioNames[name] ?? string(stream["codec_long_name"]) ?? name
        if let profile = string(stream["profile"]), profile.lowercased() != "unknown" { return "\(base) \(profile)" }
        return base
    }

    private static func bitDepth(_ stream: [String: Any]) -> Int? {
        for key in ["bits_per_raw_sample", "bits_per_sample"] {
            if let n = number(stream[key]), n > 0 { return Int(n) }
        }
        return nil
    }

    // MARK: Frame rate, date, timecode

    private static func frameRate(_ stream: [String: Any]) -> Double? {
        for key in ["avg_frame_rate", "r_frame_rate"] {
            guard let raw = string(stream[key]) else { continue }
            let parts = raw.split(separator: "/").compactMap { Double($0) }
            if parts.count == 2, parts[1] > 0, parts[0] > 0 { return parts[0] / parts[1] }
            if parts.count == 1, parts[0] > 0 { return parts[0] }
        }
        return nil
    }

    /// «2026-10-27T03:18:54.000000Z» → «2026-10-27 03:18:54 UTC»; con scarto orario lo si riporta; senza fuso non se ne inventa uno.
    /// Nei BWF la data e l'ora arrivano separate (tag `date` + `creation_time` con la sola ora).
    static func createDate(formatTags: [String: String], streamTags: [[String: String]]) -> String? {
        for candidate in [formatTags["creation_time"]] + streamTags.map({ $0["creation_time"] }) {
            if let c = candidate, let formatted = formatISODate(c) { return formatted }
        }
        // alcuni registratori scrivono l'ora con i trattini («13-05-03»)
        if let date = formatTags["date"], let time = formatTags["creation_time"],
           date.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
           time.range(of: #"^\d{2}[:-]\d{2}[:-]\d{2}$"#, options: .regularExpression) != nil {
            return "\(date) \(time.replacingOccurrences(of: "-", with: ":"))"
        }
        return nil
    }

    private static func formatISODate(_ raw: String) -> String? {
        let pattern = #"^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}:\d{2})(?:\.\d+)?(Z|[+-]\d{2}:?\d{2})?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let d = Range(m.range(at: 1), in: raw), let t = Range(m.range(at: 2), in: raw) else { return nil }
        var text = "\(raw[d]) \(raw[t])"
        if m.range(at: 3).location != NSNotFound, let z = Range(m.range(at: 3), in: raw) {
            let zone = String(raw[z])
            text += zone == "Z" ? " UTC" : " " + (zone.contains(":") ? zone : String(zone.prefix(3)) + ":" + String(zone.suffix(2)))
        }
        return text
    }

    private static func isTimecode(_ s: String) -> Bool {
        s.range(of: #"^\d{2}:\d{2}:\d{2}[:;]\d{2,3}$"#, options: .regularExpression) != nil
    }

    /// BWF: `time_reference` = campioni dalla mezzanotte. Senza video non c'è un frame rate: ora del giorno con i millisecondi.
    private static func broadcastWaveTimeReference(formatTags: [String: String], sampleRate: Double?) -> String? {
        guard let raw = formatTags["time_reference"], let samples = Double(raw), samples > 0,
              let rate = sampleRate, rate > 0 else { return nil }
        let seconds = samples / rate
        guard seconds < 86_400 else { return nil }
        return ClipColumns.formatDuration(seconds: seconds, frameRate: nil)
    }

    // MARK: Utilità

    private static func type(_ stream: [String: Any]) -> String? { stream["codec_type"] as? String }

    private static func isAttachedPicture(_ stream: [String: Any]) -> Bool {
        ((stream["disposition"] as? [String: Any])?["attached_pic"]).flatMap(number) == 1
    }

    private static func tags(_ object: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in (object["tags"] as? [String: Any]) ?? [:] {
            if let s = string(v) { out[k.lowercased()] = s }
        }
        return out
    }

    private static func firstTag(_ all: [[String: String]], _ keys: [String]) -> String? {
        for key in keys { for t in all { if let v = t[key] { return v } } }
        return nil
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func string(_ value: Any?) -> String? {
        let s: String?
        if let v = value as? String { s = v } else if let n = value as? NSNumber { s = n.stringValue } else { s = nil }
        let t = s?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t?.isEmpty ?? true) ? nil : t
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func trimmed(_ v: Double, decimals: Int) -> String {
        var s = String(format: "%.\(decimals)f", v)
        while s.contains(".") && (s.hasSuffix("0") || s.hasSuffix(".")) { s.removeLast() }
        return s
    }
}
