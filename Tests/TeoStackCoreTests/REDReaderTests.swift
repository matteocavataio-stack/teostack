import XCTest
@testable import TeoStackCore

/// Campioni veri dell'utente: cartella `fixtures/` nella radice del repository. Se manca il file il test si salta con un messaggio chiaro.
enum RealSamples {
    static var directory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures")
    }

    static func url(_ relativePath: String) throws -> URL {
        let url = directory.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Manca il campione vero «fixtures/\(relativePath)»: lettore implementato ma NON verificato su file reali.")
        }
        return url
    }

    /// Prima corrispondenza (senza distinguere maiuscole) per estensione in `fixtures/<sottocartella>`.
    static func first(withExtension ext: String, in subfolder: String) throws -> URL {
        let dir = directory.appendingPathComponent(subfolder)
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        guard let name = files.first(where: { $0.lowercased().hasSuffix("." + ext.lowercased()) && !$0.hasPrefix(".") }) else {
            throw XCTSkip("Nessun campione .\(ext) in «fixtures/\(subfolder)»: lettore implementato ma NON verificato su file reali.")
        }
        return dir.appendingPathComponent(name)
    }
}

final class REDReaderTests: XCTestCase {
    private var synthetic: URL { Fixtures.directory.appendingPathComponent("synthetic") }

    private func oracle(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: synthetic.appendingPathComponent(name))) as? [String: Any])
    }

    private func text(_ v: Any?) -> String {
        if let n = v as? NSNumber { return n.doubleValue == n.doubleValue.rounded() ? String(Int(n.doubleValue)) : String(format: "%.9g", n.doubleValue) }
        return "\(v ?? "nil")"
    }

    private func assertEqualToExifTool(_ file: String, _ json: String) throws {
        let native = try XCTUnwrap(R3DParser.parse(url: synthetic.appendingPathComponent(file)))
        let expected = try oracle(json)
        XCTAssertEqual(Set(native.keys), Set(expected.keys), "stessi tag di ExifTool")
        for (key, want) in expected {
            XCTAssertEqual(text(native[key]), text(want), key)
        }
    }

    func testNativeParserMatchesExifToolOnVersion2() throws { try assertEqualToExifTool("red2_synthetic.R3D", "red2_synthetic.exiftool.json") }
    func testNativeParserMatchesExifToolOnVersion1() throws { try assertEqualToExifTool("red1_synthetic.R3D", "red1_synthetic.exiftool.json") }

    func testNativeParserMatchesLiveExifTool() throws {
        guard let exif = ExifToolRunner.locate() else { throw XCTSkip("ExifTool non installato") }
        for name in ["red2_synthetic.R3D", "red1_synthetic.R3D"] {
            let url = synthetic.appendingPathComponent(name)
            let live = try exif.read(file: url.path).filter { $0.key.hasPrefix("Red:") }
            let native = try XCTUnwrap(R3DParser.parse(url: url))
            XCTAssertEqual(Set(native.keys), Set(live.keys), name)
            for (k, v) in live { XCTAssertEqual(text(native[k]), text(v), "\(name) \(k)") }
        }
    }

    func testMapperVersion2() throws {
        let native = try XCTUnwrap(R3DParser.parse(url: synthetic.appendingPathComponent("red2_synthetic.R3D")))
        let m = REDMetadataMapper.map(native)
        XCTAssertEqual(m.status, .read)
        XCTAssertEqual(m.family, "RED")
        XCTAssertEqual(m.cameraModel, "RED EPIC-W")
        XCTAssertEqual(m.cameraSerial, "710-0123456")
        XCTAssertEqual(m.firmware, "7.0.1")
        XCTAssertEqual(m.reel, "A012")
        XCTAssertEqual(m.clipName, "A012_C003_1028AB_001.R3D")
        XCTAssertEqual(m.width, 4096); XCTAssertEqual(m.height, 2160)
        XCTAssertEqual(m.fps, 24)
        XCTAssertEqual(m.extraColumns["sensorFPS"], "23.976")
        XCTAssertEqual(m.extraColumns["take"], "3")
        XCTAssertEqual(m.timecodeStart, "01:02:03:04")
        XCTAssertEqual(m.creationDate, "2026-10-28 15:30", "il file non dà i secondi: non se ne aggiungono")
        XCTAssertEqual(m.whiteBalance, "5600 K")
        XCTAssertEqual(m.iso, "800")
        XCTAssertEqual(m.aperture, "2.8")
        XCTAssertEqual(m.focalLength, "35 mm")
        XCTAssertEqual(m.focusDistance, "2.50 m")
        XCTAssertEqual(m.lensModel, "Supreme Prime 35mm")
        XCTAssertEqual(m.codec, "REDCODE RAW")
        XCTAssertNil(m.duration, "la durata non sta nell'intestazione: non si inventa")
        XCTAssertNil(m.frameCount); XCTAssertNil(m.colorSpace); XCTAssertNil(m.gamma); XCTAssertNil(m.tStop)
        XCTAssertEqual(m.rawFields["Red:Sensor"], "GEMINI 5K S35")
        XCTAssertEqual(m.rawFields["Red:CameraOperator"], "Operatore Uno")
        XCTAssertNil(m.rawFields["System:FileName"])
    }

    func testMapperVersion1() throws {
        let native = try XCTUnwrap(R3DParser.parse(url: synthetic.appendingPathComponent("red1_synthetic.R3D")))
        let m = REDMetadataMapper.map(native)
        XCTAssertEqual(m.cameraModel, "RED ONE MYSTERIUM-X")
        XCTAssertEqual(m.firmware, "30")
        XCTAssertEqual(m.fps, 25)
        XCTAssertEqual(m.width, 2048)
        XCTAssertEqual(m.creationDate, "2026-03-12 10:15:30")
        XCTAssertEqual(m.iso, "320")
        XCTAssertNil(m.focalLength)
    }

    func testRegistryRoutesR3DWithoutAnyExternalTool() throws {
        let r = ReaderRegistry.standard().read(url: synthetic.appendingPathComponent("red2_synthetic.R3D"), tools: ReaderTools())
        XCTAssertEqual(r.family, "RED")
        XCTAssertEqual(r.cameraModel, "RED EPIC-W")
        XCTAssertEqual(r.columns["camera"], "RED EPIC-W")
    }

    func testGarbageTruncatedAndRenamedFilesAreHandled() throws {
        XCTAssertNil(R3DParser.parse(data: Data(repeating: 0x41, count: 100)))
        XCTAssertNil(R3DParser.parse(data: Data()))
        let good = try Data(contentsOf: synthetic.appendingPathComponent("red2_synthetic.R3D"))
        _ = R3DParser.parse(data: good.prefix(0x60))            // troncato: nessun crash
        _ = R3DParser.parse(data: good.prefix(0x1000 + 10))
        // .r3d che non è R3D → nessun lettore lo riconosce, nessun errore
        let dir = try TestSupport.makeTempDir("fake-r3d")
        let fake = dir.appendingPathComponent("x.R3D")
        try Data(repeating: 1, count: 4096).write(to: fake)
        let r = ReaderRegistry.standard().read(url: fake, tools: ReaderTools())
        XCTAssertTrue(r.isUnsupported)
    }

    func testReadingNeverModifiesTheFile() throws {
        let dir = try TestSupport.makeTempDir("r3d-ro")
        let file = dir.appendingPathComponent("clip.R3D")
        try FileManager.default.copyItem(at: synthetic.appendingPathComponent("red2_synthetic.R3D"), to: file)
        let before = try TestSupport.snapshot(of: dir)
        _ = ReaderRegistry.standard().read(url: file, tools: ReaderTools())
        XCTAssertEqual(try TestSupport.snapshot(of: dir), before)
    }

    // MARK: Campione vero

    func testRealR3DSample() throws {
        let url = try RealSamples.first(withExtension: "r3d", in: "red")
        let r = ReaderRegistry.standard().read(url: url, tools: ReaderTools.detect())
        XCTAssertEqual(r.family, "RED")
        XCTAssertNotNil(r.width)
        XCTAssertNotNil(r.fps)
        print("R3D reale:", r.columns.filter { !$0.key.hasPrefix("raw.") })
    }
}
