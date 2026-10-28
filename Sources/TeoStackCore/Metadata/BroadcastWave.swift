import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Dati di un WAV broadcast (BWF): il pacchetto `bext` e i campi iXML (scena, take, nastro, nomi delle tracce, frame rate del timecode).
public struct BroadcastWaveInfo: Equatable {
    public var originator: String?
    public var originationDate: String?        // «2026-10-27»
    public var originationTime: String?        // «13:05:03»
    /// Campioni dalla mezzanotte (timecode di inizio).
    public var timeReference: UInt64?
    public var sampleRate: Int?
    public var scene: String?
    public var take: String?
    public var tape: String?
    public var project: String?
    /// Frame rate del timecode scritto nell'iXML («25/1», «30000/1001»…) e se è drop-frame («DF») o no («NDF»).
    public var timecodeRate: String?
    public var timecodeFlag: String?
    public var trackNames: [String] = []
}

/// Legge SOLO le intestazioni di un WAV/BWF (RIFF e RF64): salta i dati audio con un `seek`, non li legge e non scrive nulla.
public enum BroadcastWaveReader {
    /// nil se il file non è un WAV oppure non contiene né `bext` né iXML.
    public static func read(path: String) -> BroadcastWaveInfo? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), (try? handle.seek(toOffset: 0)) != nil,
              let head = try? handle.read(upToCount: 12), head.count == 12 else { return nil }
        let magic = String(decoding: head.prefix(4), as: UTF8.self)
        guard (magic == "RIFF" || magic == "RF64"), String(decoding: head[8..<12], as: UTF8.self) == "WAVE" else { return nil }

        var info = BroadcastWaveInfo()
        var found = false
        var offset: UInt64 = 12
        var dataSize64: UInt64?
        for _ in 0..<256 {
            guard offset + 8 <= fileSize, (try? handle.seek(toOffset: offset)) != nil,
                  let header = try? handle.read(upToCount: 8), header.count == 8 else { break }
            let id = String(decoding: header.prefix(4), as: UTF8.self)
            var size = UInt64(le32(header, 4))
            if id == "data", size == 0xFFFF_FFFF, let d = dataSize64 { size = d }
            let body = offset + 8
            switch id {
            case "ds64":
                if let d = try? handle.read(upToCount: 28), d.count >= 16 { dataSize64 = le64(d, 8) }
            case "fmt ":
                if let d = try? handle.read(upToCount: 8), d.count == 8 { info.sampleRate = Int(le32(d, 4)) }
            case "bext":
                if let d = try? handle.read(upToCount: Int(min(size, 1_000_000))), parseBext(d, into: &info) { found = true }
            case "iXML":
                if let d = try? handle.read(upToCount: Int(min(size, 4_000_000))), parseIXML(d, into: &info) { found = true }
            default: break
            }
            offset = body + size + (size & 1)
        }
        return found ? info : nil
    }

    // MARK: bext

    /// Struttura del pacchetto bext (EBU Tech 3285): descrizione 256, originator 32, riferimento 32, data 10, ora 8, time reference 8 byte…
    static func parseBext(_ d: Data, into info: inout BroadcastWaveInfo) -> Bool {
        guard d.count >= 346 else { return false }
        func text(_ range: Range<Int>) -> String? {
            let bytes = d[d.startIndex + range.lowerBound ..< d.startIndex + range.upperBound].prefix { $0 != 0 }
            let s = (String(data: Data(bytes), encoding: .isoLatin1) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        }
        info.originator = text(256..<288)
        if let date = text(320..<330) { info.originationDate = date.replacingOccurrences(of: ":", with: "-") }
        if let time = text(330..<338) { info.originationTime = time.replacingOccurrences(of: "-", with: ":") }
        info.timeReference = UInt64(le32(d, 338)) | (UInt64(le32(d, 342)) << 32)
        return true
    }

    // MARK: iXML

    static func parseIXML(_ data: Data, into info: inout BroadcastWaveInfo) -> Bool {
        // il blocco può avere spazi o byte nulli dopo l'ultimo tag
        var end = data.count
        while end > 0, data[data.startIndex + end - 1] != UInt8(ascii: ">") { end -= 1 }
        guard end > 0 else { return false }
        let delegate = IXMLDelegate()
        let parser = XMLParser(data: data.prefix(end))
        parser.delegate = delegate
        _ = parser.parse()
        let v = delegate.values
        info.scene = v["BWFXML/SCENE"]
        info.take = v["BWFXML/TAKE"]
        info.tape = v["BWFXML/TAPE"]
        info.project = v["BWFXML/PROJECT"]
        info.timecodeRate = v["BWFXML/SPEED/TIMECODE_RATE"]
        info.timecodeFlag = v["BWFXML/SPEED/TIMECODE_FLAG"]
        info.trackNames = delegate.trackNames
        return !v.isEmpty || !delegate.trackNames.isEmpty
    }

    private final class IXMLDelegate: NSObject, XMLParserDelegate {
        var values: [String: String] = [:]
        var trackNames: [String] = []
        private var path: [String] = []
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            path.append(elementName)
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = path.joined(separator: "/")
            if !value.isEmpty {
                if key == "BWFXML/TRACK_LIST/TRACK/NAME" { trackNames.append(value) } else if values[key] == nil { values[key] = value }
            }
            text = ""
            _ = path.popLast()
        }
    }

    private static func le32(_ d: Data, _ at: Int) -> UInt32 {
        let i = d.startIndex + at
        return UInt32(d[i]) | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2]) << 16 | UInt32(d[i + 3]) << 24
    }

    private static func le64(_ d: Data, _ at: Int) -> UInt64 {
        UInt64(le32(d, at)) | (UInt64(le32(d, at + 4)) << 32)
    }
}

/// Metadata audio di un BWF: solo ciò che il file dichiara (bext + iXML).
public enum BroadcastWaveMetadataParser {
    public static func parse(_ info: BroadcastWaveInfo) -> [String: String] {
        var out: [String: String] = [:]
        if let v = info.originator { out["recorder"] = v }
        if let v = info.scene { out["scene"] = v }
        if let v = info.take { out["take"] = v }
        if let v = info.tape { out["reel"] = v }
        if !info.trackNames.isEmpty { out["trackNames"] = info.trackNames.joined(separator: ", ") }
        if let d = info.originationDate, let t = info.originationTime { out["createDate"] = "\(d) \(t)" }
        if let tc = timecode(info) { out["timecode"] = tc }
        return out
    }

    /// Timecode di inizio = `time_reference` (campioni dalla mezzanotte) / frequenza di campionamento.
    /// Con il frame rate INTERO del timecode scritto nell'iXML (24, 25, 30, 50, 60…; non drop-frame) → HH:MM:SS:FF (il frame è quello in corso:
    /// parte intera). Senza frame rate, con drop-frame o con frame rate frazionari (23,976, 29,97…: il legame tra campioni e frame dipende dal
    /// registratore) non si calcolano frame: ora del giorno con i millisecondi.
    static func timecode(_ info: BroadcastWaveInfo) -> String? {
        guard let ref = info.timeReference, ref > 0, let sampleRate = info.sampleRate, sampleRate > 0 else { return nil }
        let seconds = Double(ref) / Double(sampleRate)
        guard seconds < 86_400 else { return nil }
        let drop = (info.timecodeFlag ?? "").uppercased() == "DF"
        if !drop, let rate = rate(info.timecodeRate), rate > 0, abs(rate - rate.rounded()) < 1e-9 {
            let timebase = Int(rate.rounded())
            let frames = Int((seconds * rate + 1e-6).rounded(.down))
            let perMinute = timebase * 60, perHour = timebase * 3600
            return String(format: "%02d:%02d:%02d:%02d", frames / perHour, (frames % perHour) / perMinute, (frames % perMinute) / timebase, frames % timebase)
        }
        return ClipColumns.formatDuration(seconds: seconds, frameRate: nil)
    }

    private static func rate(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        let parts = raw.split(separator: "/").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        if parts.count == 2, parts[1] > 0 { return parts[0] / parts[1] }
        return parts.count == 1 ? parts[0] : nil
    }
}
