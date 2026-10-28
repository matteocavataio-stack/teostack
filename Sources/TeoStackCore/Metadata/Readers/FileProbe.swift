import Foundation

/// Tipo di contenitore riconosciuto dai primi byte del file (non solo dall'estensione).
public enum ContainerKind: Equatable {
    case riffWave          // RIFF/RF64/BW64 + WAVE
    case mxf               // chiave KLV della partition pack (anche con run-in)
    case isoBMFF(brand: String)   // MOV/MP4/M4V/CRM/BRAW…: «ftyp» o atomi QuickTime senza ftyp (brand = "")
    case r3d               // Redcode: blocco «RED1»/«RED2»
    case cine              // Phantom Cine: «CI»
    case arriRaw           // ARRIRAW .ari: «ARRI»
    case tiff              // TIFF/DNG/CinemaDNG/RAW basati su TIFF
    case jpeg
    case dpx
    case mpegProgram       // MPEG-PS (MPG, VOB)
    case mpegTransport     // MPEG-TS / M2TS / MTS (AVCHD)
    case xml
    case unknown
}

/// Sola lettura dei primi byte di un file per riconoscerne il formato. Non modifica nulla e non legge oltre `headLength`.
public struct FileProbe {
    public static let headLength = 64 * 1024

    public let url: URL
    public let ext: String
    public let size: Int64
    public let head: Data
    public let kind: ContainerKind

    public init(url: URL) {
        self.url = url
        ext = url.pathExtension.lowercased()
        var size: Int64 = 0
        var head = Data()
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            size = Int64((try? handle.seekToEnd()) ?? 0)
            try? handle.seek(toOffset: 0)
            head = (try? handle.read(upToCount: Self.headLength)) ?? Data()
        }
        self.size = size
        self.head = head
        kind = Self.detect(head: head, ext: url.pathExtension.lowercased())
    }

    /// Per i test e per chi ha già i byte.
    public init(url: URL, head: Data, size: Int64) {
        self.url = url
        ext = url.pathExtension.lowercased()
        self.size = size
        self.head = head
        kind = Self.detect(head: head, ext: url.pathExtension.lowercased())
    }

    public func hasBytes(_ bytes: [UInt8], at offset: Int = 0) -> Bool {
        guard offset >= 0, head.count >= offset + bytes.count else { return false }
        return head.subdata(in: head.startIndex + offset ..< head.startIndex + offset + bytes.count) == Data(bytes)
    }

    public func ascii(at offset: Int, length: Int) -> String? {
        guard offset >= 0, head.count >= offset + length else { return nil }
        return String(data: head.subdata(in: head.startIndex + offset ..< head.startIndex + offset + length), encoding: .isoLatin1)
    }

    static let mxfKey: [UInt8] = [0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05, 0x01, 0x01, 0x0D, 0x01, 0x02, 0x01, 0x01]

    static func detect(head: Data, ext: String) -> ContainerKind {
        let b = [UInt8](head)
        func at(_ o: Int, _ s: String) -> Bool {
            let u = Array(s.utf8)
            return b.count >= o + u.count && Array(b[o ..< o + u.count]) == u
        }
        if (at(0, "RIFF") || at(0, "RF64") || at(0, "BW64")) && at(8, "WAVE") { return .riffWave }
        if b.count >= 8, at(4, "RED1") || at(4, "RED2"), b[0] == 0, b[1] == 0 { return .r3d }
        if at(0, "ARRI") { return .arriRaw }
        if at(4, "ftyp"), b.count >= 12 { return .isoBMFF(brand: String(decoding: b[8 ..< 12], as: UTF8.self)) }
        if b.count >= 8, ["moov", "mdat", "wide", "free", "skip", "pnot"].contains(where: { at(4, $0) }) { return .isoBMFF(brand: "") }
        if b.count >= 13, findMXF(b) { return .mxf }
        if at(0, "SDPX") || at(0, "XPDS") { return .dpx }
        if b.count >= 4, (b[0] == 0x49 && b[1] == 0x49 && b[2] == 0x2A && b[3] == 0) || (b[0] == 0x4D && b[1] == 0x4D && b[2] == 0 && b[3] == 0x2A) { return .tiff }
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return .jpeg }
        // Phantom Cine: WORD tipo «CI» (0x4943 little-endian) e WORD dimensione intestazione (44)
        if b.count >= 4, b[0] == 0x43, b[1] == 0x49, b[2] == 0x2C, b[3] == 0 { return .cine }
        if b.count >= 4, b[0] == 0x00, b[1] == 0x00, b[2] == 0x01, b[3] == 0xBA { return .mpegProgram }
        if isTransportStream(b) { return .mpegTransport }
        if at(0, "<?xml") || (b.first == 0xEF && at(3, "<?xml")) { return .xml }
        return .unknown
    }

    private static func findMXF(_ b: [UInt8]) -> Bool {
        // la partition pack può essere preceduta da un run-in (fino a 64 KiB)
        let key = mxfKey
        guard b.count >= key.count else { return false }
        var i = 0
        while i + key.count <= b.count {
            if b[i] == key[0] {
                if Array(b[i ..< i + key.count]) == key { return true }
            }
            i += 1
        }
        return false
    }

    private static func isTransportStream(_ b: [UInt8]) -> Bool {
        func sync(_ start: Int, _ stride: Int) -> Bool {
            guard b.count > start + stride * 4 else { return false }
            return (0 ..< 5).allSatisfy { b[start + $0 * stride] == 0x47 }
        }
        return sync(0, 188) || sync(4, 192)
    }
}
