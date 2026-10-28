import Foundation

/// Intestazione di un file Phantom Cine (.cine, Vision Research), little-endian.
///
/// Struttura (formato «Cine File Format» di Vision Research): CINEFILEHEADER di 44 byte → `BITMAPINFOHEADER` a `OffImageHeader`
/// → `SETUP` a `OffSetup`, che inizia con `FrameRate16` e `Shutter16`.
/// ATTENZIONE: scritto dalla documentazione del formato, NON verificato su un file reale (nessun campione né strumento di riferimento).
public enum CineParser {
    public struct Info: Equatable {
        public var compression: Int
        public var version: Int
        public var firstMovieImage: Int
        public var totalImageCount: Int
        public var firstImageNo: Int
        public var imageCount: Int
        public var width: Int?
        public var height: Int?
        public var bitCount: Int?
        public var frameRate16: Int?
        public var shutter16Microseconds: Int?
    }

    public static func parse(url: URL) -> Info? {
        guard let handle = try? FileHandle(forReadingFrom: url), let data = try? handle.read(upToCount: 1 << 20) else { return nil }
        try? handle.close()
        return parse(data: data)
    }

    public static func parse(data: Data) -> Info? {
        let b = [UInt8](data)
        guard b.count >= 44, b[0] == 0x43, b[1] == 0x49, u16(b, 2) == 44 else { return nil }
        var info = Info(compression: Int(u16(b, 4)), version: Int(u16(b, 6)), firstMovieImage: Int(i32(b, 8)),
                        totalImageCount: Int(u32(b, 12)), firstImageNo: Int(i32(b, 16)), imageCount: Int(u32(b, 20)))
        let offHeader = Int(u32(b, 24)), offSetup = Int(u32(b, 28))
        if offHeader >= 44, offHeader + 16 <= b.count, u32(b, offHeader) >= 40 {
            let w = Int(i32(b, offHeader + 4)), h = Int(i32(b, offHeader + 8)), bits = Int(u16(b, offHeader + 14))
            if w > 0 { info.width = w }
            if h != 0 { info.height = abs(h) }      // altezza negativa = immagine capovolta
            if bits > 0 { info.bitCount = bits }
        }
        if offSetup >= 44, offSetup + 4 <= b.count {
            let fr = Int(u16(b, offSetup)), sh = Int(u16(b, offSetup + 2))
            if fr > 0 { info.frameRate16 = fr }
            if sh > 0 { info.shutter16Microseconds = sh }
        }
        return info
    }

    private static func u16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24 }
    private static func i32(_ b: [UInt8], _ o: Int) -> Int32 { Int32(bitPattern: u32(b, o)) }
}

/// Phantom (Vision Research): .cine. Lettura nativa; nessun programma esterno. NON verificato su file reali.
public struct PhantomReader: MetadataReader {
    public let family = "Phantom"
    public let extensions: Set<String> = ["cine"]
    public init() {}

    public func canRead(_ file: ClipFile) -> Bool { file.probe.kind == .cine || (file.ext == "cine" && file.probe.kind == .unknown) }

    public func read(_ file: ClipFile) -> ClipMetadata {
        guard let info = CineParser.parse(url: file.url) else { return .unsupported() }
        var m = ClipMetadata()
        m.family = family
        m.container = "Cine"
        m.cameraMake = "Vision Research"   // il formato .cine è di Vision Research (Phantom)
        m.width = info.width
        m.height = info.height
        if info.imageCount > 0 { m.frameCount = info.imageCount }
        if let fps = info.frameRate16 { m.fps = Double(fps) }
        if let us = info.shutter16Microseconds, us > 0 { m.shutter = ExifMapper.shutterText(Double(us) / 1_000_000) }
        if let bits = info.bitCount { m.rawFields["Cine:BitCount"] = String(bits) }
        m.rawFields["Cine:Compression"] = String(info.compression)
        m.rawFields["Cine:Version"] = String(info.version)
        m.rawFields["Cine:FirstImageNo"] = String(info.firstImageNo)
        m.rawFields["Cine:TotalImageCount"] = String(info.totalImageCount)
        m.diagnostics = [.note(tr("Lettore .cine implementato ma non verificato su file reali."))]
        m.status = .partial
        return m
    }
}
