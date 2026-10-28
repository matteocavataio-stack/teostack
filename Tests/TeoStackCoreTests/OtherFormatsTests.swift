import XCTest
@testable import TeoStackCore

/// Costruisce un .cine sintetico secondo la documentazione del formato (NON è un file di camera): prova solo che il lettore interpreta i campi come documentato.
private func makeCine(width: Int32 = 1280, height: Int32 = 800, frames: UInt32 = 500, fps: UInt16 = 1000, shutterUs: UInt16 = 900, bits: UInt16 = 16) -> Data {
    var d = Data(count: 44 + 40 + 64)
    func put16(_ v: UInt16, _ o: Int) { d[o] = UInt8(v & 0xFF); d[o + 1] = UInt8(v >> 8) }
    func put32(_ v: UInt32, _ o: Int) { for i in 0..<4 { d[o + i] = UInt8((v >> (8 * UInt32(i))) & 0xFF) } }
    put16(0x4943, 0); put16(44, 2); put16(2, 4); put16(1, 6)
    put32(UInt32(bitPattern: -10), 8); put32(frames, 12); put32(UInt32(bitPattern: -10), 16); put32(frames, 20)
    put32(44, 24); put32(44 + 40, 28); put32(0, 32)
    put32(40, 44); put32(UInt32(bitPattern: width), 48); put32(UInt32(bitPattern: height), 52); put16(1, 56); put16(bits, 58)
    put16(fps, 44 + 40); put16(shutterUs, 44 + 42)
    return d
}

final class PhantomAndOtherFormatsTests: XCTestCase {
    func testCineHeader() throws {
        let info = try XCTUnwrap(CineParser.parse(data: makeCine()))
        XCTAssertEqual(info.width, 1280); XCTAssertEqual(info.height, 800)
        XCTAssertEqual(info.imageCount, 500); XCTAssertEqual(info.frameRate16, 1000); XCTAssertEqual(info.shutter16Microseconds, 900)
        XCTAssertEqual(info.bitCount, 16); XCTAssertEqual(info.firstImageNo, -10)
        XCTAssertNil(CineParser.parse(data: Data(repeating: 0, count: 100)))
        XCTAssertNil(CineParser.parse(data: makeCine().prefix(20)))
    }

    func testPhantomReaderIsPartialAndDeclaresItIsUnverified() throws {
        let dir = try TestSupport.makeTempDir("cine")
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("Cine1.cine")
        try makeCine().write(to: f)
        let m = ReaderRegistry.standard().read(url: f, tools: ReaderTools())
        XCTAssertEqual(m.family, "Phantom")
        XCTAssertEqual(m.status, .partial)
        XCTAssertEqual(m.width, 1280); XCTAssertEqual(m.frameCount, 500); XCTAssertEqual(m.fps, 1000)
        XCTAssertEqual(m.shutter, "1/1111")
        XCTAssertNil(m.duration, "la durata di riproduzione non sta nell'intestazione")
        XCTAssertNil(m.iso); XCTAssertNil(m.lensModel)
        XCTAssertTrue(m.diagnostics.contains { if case .note = $0 { return true } else { return false } })
    }

    func testARRIRawSignatureWithoutArtCmdGivesIdentityOnly() throws {
        let dir = try TestSupport.makeTempDir("ari")
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("A001C001.ari")
        try (Data("ARRI".utf8) + Data(repeating: 0, count: 4092)).write(to: f)
        let m = ReaderRegistry.standard().read(url: f, tools: ReaderTools())
        XCTAssertEqual(m.status, .partial)
        XCTAssertEqual(m.container, "ARRIRAW")
        XCTAssertNil(m.width, "senza art-cmd la risoluzione non si legge: non si indovina")
        XCTAssertNil(m.iso)
    }

    func testUndecodableCodecFourCCsUseTheNameOfTheFormat() {
        func label(_ tag: String, name: String? = nil) -> String? {
            var stream: [String: Any] = ["codec_type": "video", "codec_tag_string": tag]
            if let name { stream["codec_name"] = name }
            return FFprobeMetadataParser.videoCodecLabel(stream)
        }
        XCTAssertEqual(label("aprn", name: "unknown"), "Apple ProRes RAW")
        XCTAssertEqual(label("aprh"), "Apple ProRes RAW HQ")
        XCTAssertEqual(label("braw"), "Blackmagic RAW")
        XCTAssertNil(label("zzzz"), "FourCC sconosciuto: nessun nome inventato")
    }

    func testBRAWIdentityWhenNothingElseIsReadable() throws {
        let dir = try TestSupport.makeTempDir("braw")
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("A001_0001.braw")
        try (Data([0, 0, 0, 0x14]) + Data("ftypqt  ".utf8) + Data(repeating: 0, count: 4000)).write(to: f)
        let m = ReaderRegistry.standard().read(url: f, tools: ReaderTools())
        XCTAssertEqual(m.family, "Blackmagic")
        XCTAssertEqual(m.container, "BRAW")
        XCTAssertEqual(m.codec, "Blackmagic RAW")
        XCTAssertEqual(m.status, .partial)
        XCTAssertNil(m.width)
    }

    func testKRWIdentityWhenNothingElseIsReadable() throws {
        let dir = try TestSupport.makeTempDir("krw")
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("clip.krw")
        try Data(repeating: 9, count: 4000).write(to: f)
        let m = ReaderRegistry.standard().read(url: f, tools: ReaderTools())
        XCTAssertEqual(m.family, "Kinefinity")
        XCTAssertEqual(m.status, .partial)
    }
}
