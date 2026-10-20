import XCTest
@testable import TeoStackCore

enum Fixtures {
    static var directory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    }

    /// Output reale di `exiftool -json -G1 -n` su un clip MXF di una ARRI ALEXA 35 (percorso anonimizzato).
    static var arriAlexa35: URL { directory.appendingPathComponent("arri_alexa35_mxf_exiftool.json") }

    static func tags(_ url: URL) throws -> [String: Any] {
        try ExifToolRunner.parse(Data(contentsOf: url))
    }
}

final class ARRIMetadataParserTests: XCTestCase {
    func testParsesRealAlexa35MXF() throws {
        let tags = try Fixtures.tags(Fixtures.arriAlexa35)
        XCTAssertTrue(ARRIMetadataParser.canParse(tags))
        let m = ARRIMetadataParser.parse(tags)
        XCTAssertEqual(m["camera"], "ALEXA 35")
        XCTAssertEqual(m["firmware"], "SUP 5.01.00")
        XCTAssertEqual(m["resolution"], "2048x1152")
        XCTAssertEqual(m["frameRate"], "24")
        XCTAssertEqual(m["durationSeconds"], "6.875")
        XCTAssertEqual(m["timecode"], "13:23:05:17")
        XCTAssertEqual(m["createDate"], "2025-10-20 13:23:07")
    }

    func testNeverInventsValuesExifToolDoesNotProvide() throws {
        let m = ARRIMetadataParser.parse(try Fixtures.tags(Fixtures.arriAlexa35))
        for key in ["iso", "whiteBalance", "lens", "ndFilter", "lookInfo", "sensorFPS", "codec"] {
            XCTAssertNil(m[key], "«\(key)» non è nei tag di ExifTool: deve restare assente (N/D)")
        }
    }

    func testRealClipDurationAndColumns() throws {
        let m = ARRIMetadataParser.parse(try Fixtures.tags(Fixtures.arriAlexa35))
        let clip = ClipRecord(id: 1, offloadID: 1, binID: 1, relativePath: "x.mxf", name: "x.mxf", size: 1, sourceHash: nil, status: "ok",
                              destinationStatuses: ["ok"], isMedia: true, metadata: m, offloadDate: Date(), binName: "b", dayName: "d")
        func v(_ id: String) -> String { ClipColumns.value(ClipColumns.column(id: id)!, of: clip) }
        XCTAssertEqual(v("camera"), "ALEXA 35")
        XCTAssertEqual(v("duration"), "00:00:06:21")      // 6,875 s × 24 fps = 165 frame
        XCTAssertEqual(v("timecode"), "13:23:05:17")
        XCTAssertEqual(v("resolution"), "2048x1152")
        XCTAssertEqual(v("iso"), "N/D")
        XCTAssertEqual(v("lens"), "N/D")
        XCTAssertEqual(v("codec"), "N/D")
    }

    func testOtherManufacturersAreNotParsedAsARRI() {
        XCTAssertFalse(ARRIMetadataParser.canParse(["MXF:ApplicationSupplierName": "SONY"]))
        XCTAssertFalse(ARRIMetadataParser.canParse([:]))
        XCTAssertFalse(ARRIMetadataParser.canParse(["File:FileType": "MOV"]))
    }

    func testTimecodeMath() {
        XCTAssertEqual(ARRIMetadataParser.timecode(seconds: 48185.7083333333, editRate: 24, timebase: 24), "13:23:05:17")
        XCTAssertEqual(ARRIMetadataParser.timecode(seconds: 0, editRate: 25, timebase: 25), "00:00:00:00")
        XCTAssertEqual(ARRIMetadataParser.timecode(seconds: 3600 + 60 + 1 + 0.48, editRate: 25, timebase: 25), "01:01:01:12")
        // 23.976 fps: timebase 24, i frame si contano sul vero frame rate
        XCTAssertEqual(ARRIMetadataParser.timecode(seconds: 1156457.0 / (24000.0 / 1001.0), editRate: 24000.0 / 1001.0, timebase: 24), "13:23:05:17")
    }

    func testDropFrameTimecodeIsNotInvented() throws {
        var tags = try Fixtures.tags(Fixtures.arriAlexa35)
        tags["Track6:DropFrame"] = true
        XCTAssertNil(ARRIMetadataParser.parse(tags)["timecode"])
    }

    func testResolutionFallsBackToTrackTags() throws {
        var tags = try Fixtures.tags(Fixtures.arriAlexa35)
        tags.removeValue(forKey: "Composite:ImageSize")
        XCTAssertEqual(ARRIMetadataParser.parse(tags)["resolution"], "2048x1152")
        tags.removeValue(forKey: "Track5:ImageWidth")
        XCTAssertNil(ARRIMetadataParser.parse(tags)["resolution"])
    }

    func testDurationFormatting() {
        XCTAssertEqual(ClipColumns.formatDuration(seconds: 6.875, frameRate: 24), "00:00:06:21")
        XCTAssertEqual(ClipColumns.formatDuration(seconds: 6.875, frameRate: 23.976), "00:00:06.875")
        XCTAssertEqual(ClipColumns.formatDuration(seconds: 3725.5, frameRate: nil), "01:02:05.500")
    }
}

final class ExternalToolsTests: XCTestCase {
    func makeFakeTool(_ dir: URL, name: String, script: String) throws -> String {
        let url = dir.appendingPathComponent(name)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func testDetectsToolsAndVersion() throws {
        let dir = try TestSupport.makeTempDir("tools")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try makeFakeTool(dir, name: "exiftool", script: "#!/bin/sh\necho 13.59\n")
        let status = ExternalTools.detect(.exiftool, searchDirectories: [dir.path], pathEnvironment: "")
        XCTAssertTrue(status.isAvailable)
        XCTAssertEqual(status.path, path)
        XCTAssertEqual(status.version, "13.59")
        XCTAssertFalse(ExternalTools.detect(.ffprobe, searchDirectories: [dir.path], pathEnvironment: "").isAvailable)
    }

    func testMissingToolIsReportedNotFoundAndHasInstructions() {
        let status = ExternalTools.detect(.exiftool, searchDirectories: ["/nonexistent"], pathEnvironment: "/nonexistent2")
        XCTAssertFalse(status.isAvailable)
        XCTAssertNil(status.version)
        for tool in ExternalTool.allCases { XCTAssertTrue(tool.installInstructions.contains("curl")) }
        XCTAssertTrue(ExternalTool.exiftool.isRequired)
        XCTAssertFalse(ExternalTool.ffprobe.isRequired)
    }

    func testBrokenToolIsNotConsideredAvailable() throws {
        let dir = try TestSupport.makeTempDir("tools")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try makeFakeTool(dir, name: "exiftool", script: "#!/bin/sh\nexit 3\n")
        XCTAssertFalse(ExternalTools.detect(.exiftool, searchDirectories: [dir.path], pathEnvironment: "").isAvailable)
    }
}

final class MetadataImporterTests: XCTestCase {
    var store: ProjectStore!
    var card: FakeCard!
    var destBase: URL!
    var toolsDir: URL!

    override func setUpWithError() throws {
        store = try ProjectStore(path: nil)
        card = try FakeCard.create()
        destBase = try TestSupport.makeTempDir("dest")
        toolsDir = try TestSupport.makeTempDir("tools")
    }

    override func tearDown() {
        for u in [card.root.deletingLastPathComponent(), destBase, toolsDir] { try? FileManager.default.removeItem(at: u!) }
    }

    private func fakeExifTool(output: String) throws -> ExifToolRunner {
        let outFile = toolsDir.appendingPathComponent("out-\(UUID().uuidString).json")
        try output.write(to: outFile, atomically: true, encoding: .utf8)
        let script = toolsDir.appendingPathComponent("exiftool-\(UUID().uuidString)")
        try "#!/bin/sh\nif [ \"$1\" = \"-ver\" ]; then echo 13.59; exit 0; fi\ncat '\(outFile.path)'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return ExifToolRunner(executable: script.path)
    }

    private func offloadedBin() throws -> (TreeNode, URL) {
        let p = try store.createProject(name: "Film")
        let bin = try store.createBin(dayID: try store.createDay(projectID: p.id, name: "D1").id, name: "a001")
        let dest = destBase.appendingPathComponent("a001")
        let scan = try SourceScanner.scan(root: card.root)
        let job = OffloadJob(sourceURL: card.root, destinationRoots: [dest])
        try store.beginOffload(jobID: job.id, binID: bin.id, sourcePath: card.root.path, destinations: [dest.path])
        let result = OffloadEngine(job: job, scan: scan).run()
        XCTAssertTrue(result.allOK)
        try store.finishOffload(result)
        return (bin, dest)
    }

    func testImportsARRIMetadataIntoTheDatabase() throws {
        let (bin, _) = try offloadedBin()
        let runner = try fakeExifTool(output: String(contentsOf: Fixtures.arriAlexa35))
        let clips = try store.clips(underNode: bin.id)
        XCTAssertEqual(clips.count, 4)
        let summary = try MetadataImporter.importMetadata(for: clips, store: store, runner: runner)
        XCTAssertEqual(summary.read, 4)
        XCTAssertEqual(summary.unsupported, 0)
        let after = try store.clips(underNode: bin.id)
        XCTAssertTrue(after.allSatisfy { $0.metadata["camera"] == "ALEXA 35" && $0.metadata["timecode"] == "13:23:05:17" })
        XCTAssertTrue(after.allSatisfy { $0.metadata["iso"] == nil })
        // anche tramite l'offload
        let jobClips = try store.clips(forJobID: try XCTUnwrap(try store.offloads(binID: bin.id).first?.jobID))
        XCTAssertEqual(jobClips.count, 4)
    }

    func testUnknownFormatWritesNothingAndIsCounted() throws {
        let (bin, _) = try offloadedBin()
        let runner = try fakeExifTool(output: #"[{"File:FileType":"MXF","MXF:ApplicationSupplierName":"Altro"}]"#)
        let summary = try MetadataImporter.importMetadata(for: try store.clips(underNode: bin.id), store: store, runner: runner)
        XCTAssertEqual(summary.read, 0)
        XCTAssertEqual(summary.unsupported, 4)
        XCTAssertTrue(try store.clips(underNode: bin.id).allSatisfy { $0.metadata.isEmpty })
    }

    func testMissingDestinationFileIsSkippedNotInvented() throws {
        let (bin, dest) = try offloadedBin()
        try FileManager.default.removeItem(at: dest.appendingPathComponent("CLIP/C0001.MXF"))
        let runner = try fakeExifTool(output: String(contentsOf: Fixtures.arriAlexa35))
        let summary = try MetadataImporter.importMetadata(for: try store.clips(underNode: bin.id), store: store, runner: runner)
        XCTAssertEqual(summary.read, 3)
        XCTAssertEqual(summary.missingFile, 1)
        XCTAssertTrue(summary.text.contains("1 file non raggiungibili"))
    }

    func testToolFailureIsReportedPerClip() throws {
        let (bin, _) = try offloadedBin()
        let script = toolsDir.appendingPathComponent("exiftool-bad")
        try "#!/bin/sh\necho 'File format error' >&2\nexit 1\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let summary = try MetadataImporter.importMetadata(for: try store.clips(underNode: bin.id), store: store,
                                                          runner: ExifToolRunner(executable: script.path))
        XCTAssertEqual(summary.failed.count, 4)
        XCTAssertTrue(summary.failed[0].contains("File format error"))
        XCTAssertEqual(summary.read, 0)
    }

    func testMissingExifToolStopsWithClearError() throws {
        let (bin, _) = try offloadedBin()
        XCTAssertThrowsError(try MetadataImporter.importMetadata(for: try store.clips(underNode: bin.id), store: store,
                                                                 runner: ExifToolRunner(executable: "/nonexistent/exiftool"))) { error in
            guard case MetadataError.toolMissing = error else { return XCTFail("\(error)") }
        }
    }

    func testInvalidJSONIsAnError() throws {
        XCTAssertThrowsError(try ExifToolRunner.parse(Data("non è json".utf8)))
        XCTAssertThrowsError(try ExifToolRunner.parse(Data("[]".utf8)))
    }
}
