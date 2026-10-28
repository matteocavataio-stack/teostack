import Foundation

/// Lettura nativa dell'intestazione di un file Redcode (.R3D, versioni 1 e 2). Sola lettura, solo dei primi blocchi del file.
///
/// Struttura (come documentata nei sorgenti di ExifTool, `Image::ExifTool::Red`, a cui i nomi dei tag corrispondono):
/// - ogni blocco inizia con una dimensione `int32u` (big-endian) e un tipo di 4 caratteri; il primo è «RED1» o «RED2»;
/// - dopo le intestazioni c'è una «directory Red»: voci `[lunghezza int16u][tag int16u][dati]`, dove i 4 bit alti del tag danno il formato del dato.
/// I valori restituiti sono quelli che `exiftool -json -G1 -n` dà nel gruppo «Red» (stesse chiavi, stessi numeri).
public enum R3DParser {
    /// Quanti byte servono al massimo dal file (primo blocco + secondo blocco delle versioni 1).
    static let maxRead = 1 << 20

    public static func parse(url: URL) -> [String: Any]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxRead), data.count >= 8 else { return nil }
        return parse(data: data)
    }

    public static func parse(data: Data) -> [String: Any]? {
        let b = [UInt8](data)
        guard b.count >= 8, b[0] == 0, b[1] == 0, b[4] == 0x52, b[5] == 0x45, b[6] == 0x44, b[7] == 0x31 || b[7] == 0x32 else { return nil }
        let version = b[7] == 0x31 ? 1 : 2
        let size = Int(u32(b, 0))
        guard size >= 8, size <= b.count else { return nil }
        var tags: [String: Any] = [:]
        let block = Array(b[0 ..< size])

        tags["Red:RedcodeVersion"] = number(String(UnicodeScalar(block[7])))
        var buffer: [UInt8]
        var pos: Int
        if version == 1 {
            if block.count > 0x3c { tags["Red:ImageWidth"] = Int(u16(block, 0x36)); tags["Red:ImageHeight"] = Int(u16(block, 0x3a)) }
            if block.count >= 0x42 {
                let den = Double(u16(block, 0x40)), num = Double(u16(block, 0x3e))
                if den != 0 { tags["Red:FrameRate"] = num / den }
            }
            if block.count >= 0x43 + 32 { tags["Red:OriginalFileName"] = string(Array(block[0x43 ..< 0x43 + 32])) }
            // la directory sta nel secondo blocco
            guard size < b.count else { return tags }
            buffer = Array(b[size ..< min(b.count, size + 0x10000)])
            pos = 0x22
        } else {
            if block.count >= 0x54 { tags["Red:ImageWidth"] = Int(u32(block, 0x4c)); tags["Red:ImageHeight"] = Int(u32(block, 0x50)) }
            if block.count >= 0x5c {
                let a0 = Double(u16(block, 0x56)), a1 = Double(u16(block, 0x58)), a2 = Double(u16(block, 0x5a))
                if a0 != 0 { tags["Red:FrameRate"] = (a1 * 65536 + a2) / a0 }
            }
            guard block.count >= 0x41 else { return tags }
            buffer = block
            pos = 0x44 + Int(block[0x40]) * 0x18
        }

        var dirEnd: Int
        if pos + 8 > buffer.count {
            return tags
        }
        let dirLen = Int(u16(buffer, pos))
        if dirLen < 300 || dirLen >= 2048 || pos + 2 + dirLen > buffer.count {
            // «il modo difficile»: il tag 0x1000 con lunghezza 0x000f sta vicino all'inizio della directory
            guard let found = find([0x00, 0x0F, 0x10, 0x00], in: buffer) else { return tags }
            pos = found
            dirEnd = buffer.count
        } else {
            pos += 2
            dirEnd = pos + dirLen
        }
        while pos + 4 <= dirEnd {
            let len = Int(u16(buffer, pos))
            if len < 4 || pos + len > dirEnd { break }
            let tag = Int(u16(buffer, pos + 2))
            let payload = Array(buffer[pos + 4 ..< pos + len])
            guard let format = Format(rawValue: tag >> 12) else { break }
            if let name = tagNames[tag], let value = decode(tag: tag, format: format, payload: payload) {
                tags["Red:" + name] = value
            }
            pos += len
        }
        return tags
    }

    // MARK: Tag

    enum Format: Int { case int8u = 0, string, float, int8u2, int16u, int8s, int32s, undef, int32u, undef2 }

    static let tagNames: [Int: String] = [
        0x1000: "StartEdgeCode", 0x1001: "StartTimecode", 0x1002: "OtherDate1", 0x1003: "OtherDate2", 0x1004: "OtherDate3",
        0x1005: "DateTimeOriginal", 0x1006: "SerialNumber", 0x1019: "CameraType", 0x101a: "ReelNumber", 0x101b: "Take",
        0x1023: "DateCreated", 0x1024: "TimeCreated", 0x1025: "FirmwareVersion", 0x1029: "ReelTimecode", 0x102a: "StorageType",
        0x1030: "StorageFormatDate", 0x1031: "StorageFormatTime", 0x1032: "StorageSerialNumber", 0x1033: "StorageModel",
        0x1036: "AspectRatio", 0x1042: "Revision", 0x1056: "OriginalFileName", 0x106e: "LensMake", 0x106f: "LensNumber",
        0x1070: "LensModel", 0x1071: "Model", 0x107c: "CameraOperator", 0x1086: "VideoFormat", 0x1096: "Filter",
        0x10a0: "Brain", 0x10a1: "Sensor", 0x200d: "ColorTemperature", 0x2066: "OriginalFrameRate", 0x4037: "CropArea",
        0x403b: "ISO", 0x406a: "FNumber", 0x406b: "FocalLength", 0x606c: "FocusDistance",
    ]

    static func decode(tag: Int, format: Format, payload: [UInt8]) -> Any? {
        var value: Any?
        switch format {
        case .string:
            value = string(payload)
        case .float:
            guard payload.count >= 4 else { return nil }
            let floats = stride(from: 0, to: payload.count - 3, by: 4).map { Double(Float(bitPattern: u32(payload, $0))) }
            value = floats.count == 1 ? floats[0] : floats.map { "\($0)" }.joined(separator: " ")
        case .int8u, .int8u2:
            value = list(payload.map { Double($0) })
        case .int8s:
            value = list(payload.map { Double(Int8(bitPattern: $0)) })
        case .int16u:
            guard payload.count >= 2 else { return nil }
            value = list(stride(from: 0, to: payload.count - 1, by: 2).map { Double(u16(payload, $0)) })
        case .int32s:
            guard payload.count >= 4 else { return nil }
            value = list(stride(from: 0, to: payload.count - 3, by: 4).map { Double(Int32(bitPattern: u32(payload, $0))) })
        case .int32u:
            guard payload.count >= 4 else { return nil }
            value = list(stride(from: 0, to: payload.count - 3, by: 4).map { Double(u32(payload, $0)) })
        case .undef, .undef2:
            return nil
        }
        // ValueConv di ExifTool
        switch tag {
        case 0x1005, 0x1023, 0x1030:
            guard var s = value as? String else { return value }
            if tag == 0x1005 { s = replace(s, #"(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})"#, "$1:$2:$3 $4:$5:") }
            else { s = replace(s, #"(\d{4})(\d{2})"#, "$1:$2:") }
            return s
        case 0x1002, 0x1003, 0x1004:
            guard var s = value as? String else { return value }
            s = replace(s, #"(\d{4})_(\d{2})_"#, "$1:$2:")
            return s.replacingOccurrences(of: "_", with: " ")
        case 0x1024, 0x1031:
            guard let s = value as? String else { return value }
            return replace(s, #"(\d{2})(\d{2})"#, "$1:$2:")
        case 0x406a:
            return (value as? Double).map { $0 / 10 } ?? value
        case 0x606c:
            return (value as? Double).map { $0 / 1000 } ?? value
        default:
            return value
        }
    }

    /// Un solo valore → numero; più valori → «a b c» (come ExifTool).
    private static func list(_ values: [Double]) -> Any? {
        if values.count == 1 { return values[0] }
        return values.map { $0 == $0.rounded() ? String(Int($0)) : "\($0)" }.joined(separator: " ")
    }

    private static func replace(_ s: String, _ pattern: String, _ template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        guard let match = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return s }
        let ns = s as NSString
        let replaced = re.replacementString(for: match, in: s, offset: 0, template: template)
        return ns.replacingCharacters(in: match.range, with: replaced)
    }

    private static func string(_ bytes: [UInt8]) -> String {
        let end = bytes.firstIndex(of: 0) ?? bytes.count
        return String(decoding: bytes[0 ..< end], as: UTF8.self)
    }

    private static func number(_ s: String) -> Any { Int(s) ?? s }

    private static func find(_ pattern: [UInt8], in b: [UInt8]) -> Int? {
        guard b.count >= pattern.count else { return nil }
        for i in 0 ... b.count - pattern.count where b[i] == pattern[0] && Array(b[i ..< i + pattern.count]) == pattern { return i }
        return nil
    }

    private static func u16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) << 8 | UInt16(b[o + 1]) }
    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 { UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3]) }
}
