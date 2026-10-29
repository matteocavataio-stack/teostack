import XCTest
@testable import TeoStackCore

enum Fixtures {
    static var directory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    }

    /// Output reale di `exiftool -json -G1 -n` su un clip MXF di una ARRI ALEXA 35 (percorso anonimizzato).
    static var arriAlexa35: URL { directory.appendingPathComponent("arri_alexa35_mxf_exiftool.json") }

    /// Output reale di `art-cmd export --duration 1` (ARRI Reference Tool CMD 1.0.0) sullo stesso clip (percorso anonimizzato).
    static var artCmdExport: URL { directory.appendingPathComponent("arri_alexa35_art_cmd_export.json") }

    static func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

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
        let bin = try store.createBin(parentID: try store.createDay(projectID: p.id, name: "D1").id, name: "a001")
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


final class ARTMetadataParserTests: XCTestCase {
    func testParsesRealAlexa35Export() throws {
        let json = try Fixtures.json(Fixtures.artCmdExport)
        XCTAssertTrue(ARTMetadataParser.canParse(json))
        let m = ARTMetadataParser.parse(json)
        XCTAssertEqual(m["camera"], "ARRI ALEXA 35")
        XCTAssertEqual(m["cameraSerial"], "70253")
        XCTAssertEqual(m["firmware"], "5.01.00")
        XCTAssertEqual(m["codec"], "ARRIRAW uncompressed")
        XCTAssertEqual(m["resolution"], "2048x1152")
        XCTAssertEqual(m["sensorFPS"], "24")
        XCTAssertEqual(m["iso"], "800")
        XCTAssertEqual(m["shutter"], "1/50")
        XCTAssertEqual(m["whiteBalance"], "5600 K")
        XCTAssertEqual(m["ndFilter"], "ND 1.2")
        XCTAssertEqual(m["lookInfo"], "Default.ALF4")
        XCTAssertEqual(m["lens"], "ARRI SZ65-300 T2.8")
        XCTAssertEqual(m["focalLength"], "65 mm")          // 64968 µm
        XCTAssertEqual(m["scene"], "10A")
        XCTAssertEqual(m["take"], "19")
        XCTAssertEqual(m["reel"], "DW0001_1I7H")
        XCTAssertEqual(m["colorSpace"], "AWG4 / LogC4")
        XCTAssertEqual(m["timecode"], "13:23:05:17")
    }

    func testTimecodeMatchesTheExifToolDerivedOne() throws {
        let art = ARTMetadataParser.parse(try Fixtures.json(Fixtures.artCmdExport))
        let exif = ARRIMetadataParser.parse(try Fixtures.tags(Fixtures.arriAlexa35))
        XCTAssertEqual(art["timecode"], exif["timecode"], "due strumenti indipendenti devono dare lo stesso timecode")
        XCTAssertEqual(art["resolution"], exif["resolution"])
    }

    func testDoesNotReadClipDurationFromArtExport() throws {
        // clipDuration vale 1 perché l'export usa --duration 1: la durata vera viene da ExifTool.
        let m = ARTMetadataParser.parse(try Fixtures.json(Fixtures.artCmdExport))
        XCTAssertNil(m["durationSeconds"])
        XCTAssertNil(m["createDate"], "clipCreationTime è marcato Z ma coincide con l'ora locale del nome file: non lo uso")
    }

    func testUnavailableValuesStayAbsent() throws {
        var json = try Fixtures.json(Fixtures.artCmdExport)
        var frames = (json["frameBasedMetadata"] as! [String: Any])
        var list = frames["frames"] as! [[String: Any]]
        var sets = list[0]["frameBasedMetadataSets"] as! [String: Any]
        sets["Lens State"] = ["lensFocalLength": 0]          // 0 = "not available" nello schema ARRI
        sets.removeValue(forKey: "Filter")
        sets["White Balance"] = ["colorTemperature": 3200, "whiteBalanceTint": -1.5]
        list[0]["frameBasedMetadataSets"] = sets
        frames["frames"] = list
        json["frameBasedMetadata"] = frames
        let m = ARTMetadataParser.parse(json)
        XCTAssertNil(m["focalLength"])
        XCTAssertNil(m["ndFilter"])
        XCTAssertEqual(m["whiteBalance"], "3200 K, tint -1.5")
        XCTAssertEqual(m["lens"], "ARRI SZ65-300 T2.8", "i dati statici restano")
    }

    func testNoFramesMeansNoDynamicValues() throws {
        var json = try Fixtures.json(Fixtures.artCmdExport)
        json["frameBasedMetadata"] = ["frames": [] as [Any]]
        let m = ARTMetadataParser.parse(json)
        for key in ["iso", "ndFilter", "whiteBalance", "shutter", "sensorFPS", "timecode", "focalLength"] { XCTAssertNil(m[key], key) }
        XCTAssertEqual(m["camera"], "ARRI ALEXA 35")
    }

    func testRationalFrameRate() throws {
        var json = try Fixtures.json(Fixtures.artCmdExport)
        var frames = json["frameBasedMetadata"] as! [String: Any]
        var list = frames["frames"] as! [[String: Any]]
        var sets = list[0]["frameBasedMetadataSets"] as! [String: Any]
        var sensor = sets["Sensor State"] as! [String: Any]
        sensor["sensorSampleRate"] = "24000/1001"
        sets["Sensor State"] = sensor
        list[0]["frameBasedMetadataSets"] = sets
        frames["frames"] = list
        json["frameBasedMetadata"] = frames
        XCTAssertEqual(ARTMetadataParser.parse(json)["sensorFPS"], "23.976")
    }

    func testNotAnArtExportIsNotParsed() {
        XCTAssertFalse(ARTMetadataParser.canParse([:]))
        XCTAssertEqual(ARTMetadataParser.parse(["x": 1]), [:])
    }

    func testColumnsShowRealValues() throws {
        let m = ARTMetadataParser.parse(try Fixtures.json(Fixtures.artCmdExport))
        let clip = ClipRecord(id: 1, offloadID: 1, binID: 1, relativePath: "x.mxf", name: "x.mxf", size: 1, sourceHash: nil, status: "ok",
                              destinationStatuses: ["ok"], isMedia: true, metadata: m, offloadDate: Date(), binName: "b", dayName: "d")
        func v(_ id: String) -> String { ClipColumns.value(ClipColumns.column(id: id)!, of: clip) }
        XCTAssertEqual(v("iso"), "800")
        XCTAssertEqual(v("sensorFPS"), "24")
        XCTAssertEqual(v("ndFilter"), "ND 1.2")
        XCTAssertEqual(v("whiteBalance"), "5600 K")
        XCTAssertEqual(v("lens"), "ARRI SZ65-300 T2.8")
        XCTAssertEqual(v("lookInfo"), "Default.ALF4")
        XCTAssertEqual(v("codec"), "ARRIRAW uncompressed")
    }
}

final class ARTCmdRunnerAndImporterTests: XCTestCase {
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

    private func script(_ body: String, name: String = UUID().uuidString) throws -> String {
        let url = toolsDir.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    /// Finto art-cmd: scrive la fixture reale nel file indicato da --output (e registra gli argomenti ricevuti).
    private func fakeArt(argsLog: String? = nil) throws -> ARTCmdRunner {
        let log = argsLog.map { "echo \"$@\" >> '\($0)'" } ?? ""
        return ARTCmdRunner(executable: try script("""
        \(log)
        out=""
        while [ $# -gt 0 ]; do if [ "$1" = "--output" ]; then out="$2"; fi; shift; done
        cat '\(Fixtures.artCmdExport.path)' > "$out"
        """))
    }

    private func fakeExif(_ json: String) throws -> ExifToolRunner {
        let out = toolsDir.appendingPathComponent("o-\(UUID().uuidString).json")
        try json.write(to: out, atomically: true, encoding: .utf8)
        return ExifToolRunner(executable: try script("cat '\(out.path)'"))
    }

    private func offloadedBin() throws -> TreeNode {
        let p = try store.createProject(name: "Film")
        let bin = try store.createBin(parentID: try store.createDay(projectID: p.id, name: "D1").id, name: "a001")
        let dest = destBase.appendingPathComponent("a001")
        let job = OffloadJob(sourceURL: card.root, destinationRoots: [dest])
        try store.beginOffload(jobID: job.id, binID: bin.id, sourcePath: card.root.path, destinations: [dest.path])
        let result = OffloadEngine(job: job, scan: try SourceScanner.scan(root: card.root)).run()
        XCTAssertTrue(result.allOK)
        try store.finishOffload(result)
        return bin
    }

    func testRunnerCallsArtCmdExportWithOneFrameAndReadsJSON() throws {
        let log = toolsDir.appendingPathComponent("args.log").path
        let runner = try fakeArt(argsLog: log)
        let json = try runner.read(file: "/Volumes/X/clip.mxf")
        XCTAssertTrue(ARTMetadataParser.canParse(json))
        let args = try String(contentsOfFile: log)
        XCTAssertTrue(args.hasPrefix("export --input /Volumes/X/clip.mxf --duration 1 --output "), args)
        XCTAssertTrue(args.contains("metadata.json"))
    }

    func testRunnerCleansTemporaryFolder() throws {
        let before = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path))?.filter { $0.hasPrefix("teostack-art-") }.count ?? 0
        _ = try fakeArt().read(file: "/x.mxf")
        let after = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path))?.filter { $0.hasPrefix("teostack-art-") }.count ?? 0
        XCTAssertEqual(before, after)
    }

    func testRunnerReportsFailureWithMessage() throws {
        let bad = ARTCmdRunner(executable: try script("echo 'Unsupported file format' >&2\nexit 2"))
        XCTAssertThrowsError(try bad.read(file: "/x.mxf")) { error in
            guard case MetadataError.toolFailed(let m) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(m.contains("Unsupported file format") && m.contains("codice 2"), m)
        }
    }

    func testRunnerErrorsWhenNoJSONProduced() throws {
        let silent = ARTCmdRunner(executable: try script("exit 0"))
        XCTAssertThrowsError(try silent.read(file: "/x.mxf")) { error in
            guard case MetadataError.invalidOutput = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try ARTCmdRunner(executable: "/nonexistent/art-cmd").read(file: "/x.mxf"))
    }

    func testRunnerTimesOut() throws {
        var slow = ARTCmdRunner(executable: try script("sleep 5"))
        slow.timeout = 0.3
        XCTAssertThrowsError(try slow.read(file: "/x.mxf")) { error in
            XCTAssertTrue("\(error)".contains("non ha risposto"), "\(error)")
        }
    }

    func testImporterMergesExifToolAndArtCmd() throws {
        let bin = try offloadedBin()
        let exif = try fakeExif(String(contentsOf: Fixtures.arriAlexa35))
        let summary = try MetadataImporter.importMetadata(for: try store.clips(underNode: bin.id), store: store,
                                                          runner: exif, art: try fakeArt())
        XCTAssertEqual(summary.read, 4)
        XCTAssertTrue(summary.artFailed.isEmpty)
        let m = try XCTUnwrap(try store.clips(underNode: bin.id).first?.metadata)
        XCTAssertEqual(m["iso"], "800")                         // da art-cmd
        XCTAssertEqual(m["durationSeconds"], "6.875")           // da ExifTool (art-cmd con --duration 1 non la dà)
        XCTAssertEqual(m["camera"], "ARRI ALEXA 35")            // art-cmd prevale su "ALEXA 35" di ExifTool
        XCTAssertEqual(m["createDate"], "2025-10-20 13:23:07")  // da ExifTool
        XCTAssertEqual(m["timecode"], "13:23:05:17")
        XCTAssertEqual(summary.text, "4 clip letti")
    }

    func testArtCmdFailureKeepsExifToolValuesAndIsReported() throws {
        let bin = try offloadedBin()
        let exif = try fakeExif(String(contentsOf: Fixtures.arriAlexa35))
        let badArt = ARTCmdRunner(executable: try script("echo boom >&2\nexit 1"))
        let summary = try MetadataImporter.importMetadata(for: try store.clips(underNode: bin.id), store: store, runner: exif, art: badArt)
        XCTAssertEqual(summary.read, 4)
        XCTAssertEqual(summary.artFailed.count, 4)
        XCTAssertTrue(summary.text.contains("art-cmd non ha letto 4 clip ARRI"))
        let m = try XCTUnwrap(try store.clips(underNode: bin.id).first?.metadata)
        XCTAssertEqual(m["camera"], "ALEXA 35")
        XCTAssertNil(m["iso"], "senza art-cmd l'ISO resta N/D")
    }

    func testArtCmdAloneWorksOnMxfAndMovButSkipsOtherClips() throws {
        let bin = try offloadedBin()
        let summary = try MetadataImporter.importMetadata(for: try store.clips(underNode: bin.id), store: store, runner: nil, art: try fakeArt())
        XCTAssertEqual(summary.read, 4)       // 2 .mov + 1 .mxf + 1 .ari (ExifTool non legge gli .ari: li legge art-cmd)
        XCTAssertEqual(summary.unsupported, 0)
        let clips = try store.clips(underNode: bin.id)
        XCTAssertEqual(clips.first { $0.name == "A001C003.ari" }?.metadata["iso"], "800")
        XCTAssertEqual(clips.first { $0.name == "C0001.MXF" }?.metadata["iso"], "800")
        XCTAssertNil(clips.first { $0.name == "C0001.MXF" }?.metadata["durationSeconds"], "senza ExifTool la durata resta N/D")
    }

    func testNonARRIFileRejectedByArtCmdIsUnsupportedNotAnError() throws {
        let bin = try offloadedBin()
        let exif = try fakeExif(#"[{"MXF:ApplicationSupplierName":"Altro"}]"#)
        let failing = ARTCmdRunner(executable: try script("echo 'not an ARRI clip' >&2\nexit 1"))
        let summary = try MetadataImporter.importMetadata(for: try store.clips(underNode: bin.id), store: store, runner: exif, art: failing)
        XCTAssertEqual(summary.read, 0)
        XCTAssertTrue(summary.failed.isEmpty && summary.artFailed.isEmpty)
        XCTAssertEqual(summary.unsupported, 4)
        XCTAssertTrue(try store.clips(underNode: bin.id).allSatisfy { $0.metadata.isEmpty })
    }

    func testNoToolAtAllIsAnError() throws {
        let bin = try offloadedBin()
        XCTAssertThrowsError(try MetadataImporter.importMetadata(for: try store.clips(underNode: bin.id), store: store, runner: nil, art: nil))
    }

    func testArtCmdIsDetectedInArriFolderLayout() throws {
        // ~/ARRI/art-cmd_1.0.0_macos_universal/bin/art-cmd
        let home = toolsDir.appendingPathComponent("home")
        let bin = home.appendingPathComponent("ARRI/art-cmd_1.0.0_macos_universal/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let exe = bin.appendingPathComponent("art-cmd")
        try "#!/bin/sh\nexit 0\n".write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        let dirs = ExternalTools.artCmdSearchDirectories(home: home.path)
        XCTAssertTrue(dirs.contains(bin.path))
        let status = ExternalTools.detect(.artCmd, searchDirectories: dirs, pathEnvironment: "", userPath: "")
        XCTAssertEqual(status.path, exe.path)
        XCTAssertNil(status.version)
        XCTAssertTrue(status.isAvailable)
        XCTAssertFalse(ExternalTool.artCmd.isRequired)
        XCTAssertEqual(ExternalTools.detect(.artCmd, searchDirectories: ["/nonexistent"], pathEnvironment: "", userPath: "").isAvailable, false)
    }

    func testUserChosenPathIsUsed() throws {
        let exe = try script("exit 0", name: "art-cmd")
        let status = ExternalTools.detect(.artCmd, searchDirectories: [], pathEnvironment: "", userPath: exe)
        XCTAssertEqual(status.path, exe)
    }
}

final class ParallelRunnerTests: XCTestCase {
    func testEveryItemRunsOnceAndLimitIsRespected() throws {
        let lock = NSLock()
        var seen: [Int] = []
        var running = 0, peak = 0
        try ParallelRunner.forEach(Array(0..<60), limit: 3) { i, item in
            XCTAssertEqual(i, item)
            lock.lock(); running += 1; peak = max(peak, running); seen.append(i); lock.unlock()
            Thread.sleep(forTimeInterval: 0.005)
            lock.lock(); running -= 1; lock.unlock()
        }
        XCTAssertEqual(seen.sorted(), Array(0..<60))
        XCTAssertLessThanOrEqual(peak, 3)
        XCTAssertGreaterThan(peak, 1, "deve davvero lavorare in parallelo")
    }

    func testFirstErrorIsRethrownAndRemainingItemsAreSkipped() {
        struct Boom: Error {}
        let lock = NSLock()
        var started = 0
        XCTAssertThrowsError(try ParallelRunner.forEach(Array(0..<200), limit: 2) { i, _ in
            lock.lock(); started += 1; lock.unlock()
            if i == 3 { throw Boom() }
            Thread.sleep(forTimeInterval: 0.002)
        }) { XCTAssertTrue($0 is Boom) }
        XCTAssertLessThan(started, 200)
    }

    func testEmptyAndSingleWorker() throws {
        try ParallelRunner.forEach([Int](), limit: 4) { _, _ in XCTFail() }
        var order: [Int] = []
        try ParallelRunner.forEach([5, 6, 7], limit: 1) { _, v in order.append(v) }
        XCTAssertEqual(order, [5, 6, 7])
    }
}

final class MetadataParallelImportTests: XCTestCase {
    func testManyClipsAreReadInParallelAndAllStored() throws {
        let store = try ProjectStore(path: nil)
        let p = try store.createProject(name: "P")
        let bin = try store.createBin(parentID: try store.createDay(projectID: p.id, name: "D").id, name: "B")
        let dir = try TestSupport.makeTempDir("par-meta")
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("dest"), source = dir.appendingPathComponent("card")
        var files: [FileResult] = []
        for i in 0..<24 {
            let name = String(format: "C%03d.mxf", i)
            try TestSupport.writeRandomFile(dest.appendingPathComponent(name), size: 100, seed: UInt64(i))
            files.append(FileResult(relativePath: name, size: 100, sourceHash: "0123456789abcdef",
                                    destinations: [DestFileResult(status: .ok, destHash: "0123456789abcdef", message: nil)], modificationDate: Date()))
        }
        let job = OffloadJob(sourceURL: source, destinationRoots: [dest])
        try store.beginOffload(jobID: job.id, binID: bin.id, sourcePath: source.path, destinations: [dest.path])
        try store.finishOffload(OffloadResult(job: job, outcome: .completed, files: files, preflightErrors: [], destinationErrors: [nil],
                                              skippedAlreadyVerified: 0, elapsed: 1))
        // ExifTool finto che impiega 0,25 s per file: in serie 24 clip = 6 s
        let out = dir.appendingPathComponent("exif.json")
        try String(contentsOf: Fixtures.arriAlexa35).write(to: out, atomically: true, encoding: .utf8)
        let script = dir.appendingPathComponent("exiftool")
        try "#!/bin/sh\nif [ \"$1\" = \"-ver\" ]; then echo 13.59; exit 0; fi\nsleep 0.25\ncat '\(out.path)'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let clips = try store.clips(underNode: bin.id, mediaOnly: false)
        XCTAssertEqual(clips.count, 24)
        var lastProgress = 0
        let progressLock = NSLock()
        let start = Date()
        let summary = try MetadataImporter.importMetadata(for: clips, store: store, runner: ExifToolRunner(executable: script.path)) { done, total in
            progressLock.lock(); lastProgress = max(lastProgress, done); progressLock.unlock()
            XCTAssertEqual(total, 24)
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(summary.read, 24)
        XCTAssertEqual(lastProgress, 24)
        XCTAssertLessThan(elapsed, 4.5, "in parallelo deve battere nettamente i 6 s della lettura in serie (\(elapsed) s)")
        XCTAssertTrue(try store.clips(underNode: bin.id).allSatisfy { $0.metadata["camera"] == "ALEXA 35" })
    }
}

/// Un valore 0 o 1 nel JSON è un numero, non un booleano (prima veniva scartato: tint 0, roll 0… risultavano «N/D»).
final class JSONNumberVersusBooleanTests: XCTestCase {
    func testZeroAndOneAreNumbersWhileTrueAndFalseAreBooleans() throws {
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(#"{"zero":0,"one":1,"zerof":0.0,"t":true,"f":false,"x":2.5}"#.utf8)) as? [String: Any])
        for k in ["zero", "one", "zerof", "x"] { XCTAssertFalse((obj[k] as? NSNumber)?.isJSONBoolean ?? true, k) }
        for k in ["t", "f"] { XCTAssertTrue((obj[k] as? NSNumber)?.isJSONBoolean ?? false, k) }
        let raw = RawTags.fields(from: obj)
        XCTAssertEqual(raw["zero"], "0"); XCTAssertEqual(raw["one"], "1"); XCTAssertEqual(raw["t"], "true"); XCTAssertEqual(raw["f"], "false")
    }

    func testARRITintAndRollOfZeroAreKept() throws {
        let m = ARTMetadataParser.parse(try Fixtures.json(Fixtures.artCmdExport))
        XCTAssertEqual(m["tint"], "0", "il clip ha whiteBalanceTint 0: è un valore, non «N/D»")
        XCTAssertEqual(m["whiteBalance"], "5600 K")
        let zero: [String: Any] = ["arriJsonHeader": [:], "clipBasedMetadataSets": [], "frameBasedMetadata": ["frames": [[
            "timecode": "01:00:00:00",
            "frameBasedMetadataSets": ["Positional": ["orientation": ["roll": 0, "tilt": 1]], "Filter": ["ndFilterDensity": 0],
                                        "Sensor State": ["exposureIndex": 1, "exposureTime": "1/48"]]]]]]
        let z = ARTMetadataParser.parse(zero)
        XCTAssertEqual(z["roll"], "0"); XCTAssertEqual(z["tilt"], "1"); XCTAssertEqual(z["ndFilter"], "ND 0"); XCTAssertEqual(z["iso"], "1")
    }
}
