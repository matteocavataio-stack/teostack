import XCTest
@testable import TeoStackCore

final class ClipMetadataTests: XCTestCase {
    func testColumnsRoundTripAndNothingIsInvented() {
        var m = ClipMetadata()
        XCTAssertTrue(m.columns.isEmpty, "senza campi non esce nessun valore")
        XCTAssertFalse(m.hasValues)
        m.cameraModel = "ALEXA 35"; m.cameraMake = "ARRI"; m.width = 4608; m.height = 3164; m.fps = 24; m.duration = 6.875
        m.rawFields = ["MXF:Foo": "bar"]
        let c = m.columns
        XCTAssertEqual(c["camera"], "ALEXA 35")
        XCTAssertEqual(c["resolution"], "4608x3164")
        XCTAssertEqual(c["frameRate"], "24")
        XCTAssertEqual(c["durationSeconds"], "6.875")
        XCTAssertEqual(c["raw.MXF:Foo"], "bar")
        XCTAssertNil(c["iso"])
        let back = ClipMetadata(columns: c)
        XCTAssertEqual(back.cameraModel, "ALEXA 35")
        XCTAssertEqual(back.width, 4608)
        XCTAssertEqual(back.fps, 24)
        XCTAssertEqual(back.rawFields, ["MXF:Foo": "bar"])
        XCTAssertEqual(back.status, .read)
        XCTAssertEqual(ClipMetadata(columns: ["scene": "12A"]).extraColumns["scene"], "12A", "chiavi senza campo tipizzato si conservano")
    }
}

final class FileProbeTests: XCTestCase {
    private func kind(_ bytes: [UInt8], ext: String = "bin") -> ContainerKind {
        FileProbe(url: URL(fileURLWithPath: "/x/clip." + ext), head: Data(bytes), size: Int64(bytes.count)).kind
    }

    func testMagicBytes() {
        XCTAssertEqual(kind(Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WAVEfmt ".utf8)), .riffWave)
        XCTAssertEqual(kind(Array("BW64".utf8) + [0, 0, 0, 0] + Array("WAVE".utf8)), .riffWave)
        XCTAssertEqual(kind([0, 0, 0x10, 0] + Array("RED2".utf8) + [0, 0, 0, 0]), .r3d)
        XCTAssertEqual(kind([0, 0, 0x10, 0] + Array("RED1".utf8) + [0, 0, 0, 0]), .r3d)
        XCTAssertEqual(kind(Array("ARRI".utf8) + [0, 0, 0, 0]), .arriRaw)
        XCTAssertEqual(kind([0, 0, 0, 0x14] + Array("ftypqt  ".utf8)), .isoBMFF(brand: "qt  "))
        XCTAssertEqual(kind([0, 0, 0, 0x14] + Array("ftypcrx ".utf8)), .isoBMFF(brand: "crx "))
        XCTAssertEqual(kind([0, 0, 0, 8] + Array("moov".utf8)), .isoBMFF(brand: ""))
        XCTAssertEqual(kind([0xFF, 0xD8, 0xFF, 0xE0]), .jpeg)
        XCTAssertEqual(kind([0x49, 0x49, 0x2A, 0x00, 8, 0, 0, 0]), .tiff)
        XCTAssertEqual(kind(Array("SDPX".utf8) + [0, 0, 0, 0]), .dpx)
        XCTAssertEqual(kind([0x43, 0x49, 0x2C, 0x00, 0, 0, 0, 0]), .cine)
        XCTAssertEqual(kind([0, 0, 1, 0xBA, 0x44, 0, 4, 0]), .mpegProgram)
        XCTAssertEqual(kind([1, 2, 3, 4, 5, 6, 7, 8]), .unknown)
        XCTAssertEqual(kind([]), .unknown)
    }

    func testMXFWithRunIn() {
        let key = FileProbe.mxfKey + [0x00, 0x00]
        XCTAssertEqual(kind(key), .mxf)
        XCTAssertEqual(kind([UInt8](repeating: 0, count: 5000) + key), .mxf, "run-in prima della partition pack")
    }

    func testTransportStream() {
        var ts = [UInt8](repeating: 0, count: 188 * 6)
        for i in 0..<6 { ts[i * 188] = 0x47 }
        XCTAssertEqual(kind(ts, ext: "ts"), .mpegTransport)
        var m2ts = [UInt8](repeating: 0, count: 192 * 6)
        for i in 0..<6 { m2ts[4 + i * 192] = 0x47 }
        XCTAssertEqual(kind(m2ts, ext: "mts"), .mpegTransport)
    }

    func testProbeReadsOnlyTheHeadAndNeverWrites() throws {
        let dir = try TestSupport.makeTempDir("probe")
        let file = dir.appendingPathComponent("a.wav")
        let data = Data(Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WAVE".utf8)) + Data(repeating: 7, count: 200_000)
        try data.write(to: file)
        let before = try TestSupport.snapshot(of: dir)
        let probe = FileProbe(url: file)
        XCTAssertEqual(probe.kind, .riffWave)
        XCTAssertEqual(probe.size, Int64(data.count))
        XCTAssertEqual(probe.head.count, FileProbe.headLength)
        XCTAssertEqual(try TestSupport.snapshot(of: dir), before)
        XCTAssertEqual(FileProbe(url: dir.appendingPathComponent("missing.mov")).size, 0, "file mancante: nessun errore")
    }
}

final class ReaderRegistryTests: XCTestCase {
    private struct Fake: MetadataReader {
        let family: String
        let extensions: Set<String> = ["x"]
        let accepts: Bool
        let result: ClipMetadata
        func canRead(_ file: ClipFile) -> Bool { accepts }
        func read(_ file: ClipFile) -> ClipMetadata { result }
    }

    private func clip(_ name: String = "a.x") -> ClipFile {
        ClipFile(url: URL(fileURLWithPath: "/nonexistent/" + name), tools: ReaderTools())
    }

    private func supported(_ camera: String) -> ClipMetadata {
        var m = ClipMetadata(); m.cameraModel = camera; m.status = .read; return m
    }

    func testFirstReaderThatProducesValuesWinsAndFamilyIsFilled() {
        let registry = ReaderRegistry(readers: [
            Fake(family: "A", accepts: false, result: supported("no")),
            Fake(family: "B", accepts: true, result: .unsupported([.note("non mio")])),
            Fake(family: "C", accepts: true, result: supported("C-cam")),
            Fake(family: "D", accepts: true, result: supported("D-cam")),
        ])
        let r = registry.read(clip())
        XCTAssertEqual(r.cameraModel, "C-cam")
        XCTAssertEqual(r.family, "C")
    }

    func testNoReaderMeansUnsupportedNeverAnError() {
        let r = ReaderRegistry(readers: [Fake(family: "A", accepts: false, result: supported("x"))]).read(clip())
        XCTAssertEqual(r.status, .unsupported)
        XCTAssertTrue(r.isUnsupported)
        XCTAssertTrue(r.columns.isEmpty)
        XCTAssertTrue(ReaderRegistry().read(clip()).isUnsupported)
    }

    func testToolProblemsOfSkippedReadersAreCarried() {
        let registry = ReaderRegistry(readers: [Fake(family: "A", accepts: true, result: .unsupported([.toolFailed("boom"), .note("n")]))])
        let r = registry.read(clip())
        XCTAssertEqual(r.diagnostics, [.toolFailed("boom")])
    }

    func testStandardRegistryDoesNotCrashOnMissingFileOrTools() {
        let r = ReaderRegistry.standard().read(url: URL(fileURLWithPath: "/nonexistent/clip.mov"), tools: ReaderTools())
        XCTAssertTrue(r.isUnsupported)
    }
}
