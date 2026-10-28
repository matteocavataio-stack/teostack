import XCTest
@testable import TeoStackCore

/// WAV broadcast: `bext` + iXML. `bwf_zaxcom_header.wav` sono i primi 8 KB di un file vero registrato con uno Zaxcom Deva24
/// (intestazioni complete, audio quasi assente); `ffprobe_bwf_zaxcom.json` è l'output di ffprobe su quel file (ritagliato a 20 MB).
final class BroadcastWaveTests: XCTestCase {
    private var fixtures: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures") }
    private var header: String { fixtures.appendingPathComponent("bwf_zaxcom_header.wav").path }
    private var tmp: URL!

    override func setUpWithError() throws { tmp = try TestSupport.makeTempDir("bwf") }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    func testReadsBextAndIXMLFromARealRecorderFile() throws {
        let info = try XCTUnwrap(BroadcastWaveReader.read(path: header))
        XCTAssertEqual(info.originator, "Zaxcom Deva24")
        XCTAssertEqual(info.originationDate, "2026-10-27")
        XCTAssertEqual(info.originationTime, "13:05:03", "il registratore scrive «13-05-03»: si normalizza")
        XCTAssertEqual(info.timeReference, 2_260_692_144)
        XCTAssertEqual(info.sampleRate, 48000)
        XCTAssertEqual(info.scene, "1")
        XCTAssertEqual(info.take, "2")
        XCTAssertEqual(info.tape, "SPOTIFY_TALKS_04")
        XCTAssertEqual(info.timecodeRate, "25/1")
        XCTAssertEqual(info.timecodeFlag, "NDF")
        XCTAssertEqual(info.trackNames, ["BOOM", "RADIO 1", "RADIO 2"], "tutte le tracce, non solo la prima")
    }

    func testParsedMetadata() throws {
        let m = BroadcastWaveMetadataParser.parse(try XCTUnwrap(BroadcastWaveReader.read(path: header)))
        XCTAssertEqual(m["recorder"], "Zaxcom Deva24")
        XCTAssertEqual(m["scene"], "1")
        XCTAssertEqual(m["take"], "2")
        XCTAssertEqual(m["reel"], "SPOTIFY_TALKS_04")
        XCTAssertEqual(m["trackNames"], "BOOM, RADIO 1, RADIO 2")
        XCTAssertEqual(m["createDate"], "2026-10-27 13:05:03")
        // 2 260 692 144 campioni / 48 000 = 47 097,753 s = 13:04:57,753 → a 25 fps il frame in corso è il 18
        XCTAssertEqual(m["timecode"], "13:04:57:18")
    }

    func testTimecodeWithoutFrameRateOrWithDropFrameDoesNotInventFrames() {
        var info = BroadcastWaveInfo()
        info.timeReference = 2_260_692_144
        info.sampleRate = 48000
        XCTAssertEqual(BroadcastWaveMetadataParser.timecode(info), "13:04:57.753", "senza frame rate: ora del giorno con i millisecondi")
        info.timecodeRate = "30000/1001"
        info.timecodeFlag = "DF"
        XCTAssertEqual(BroadcastWaveMetadataParser.timecode(info), "13:04:57.753", "drop-frame: nessun calcolo di frame")
        info.timecodeFlag = "NDF"
        XCTAssertEqual(BroadcastWaveMetadataParser.timecode(info), "13:04:57.753", "29,97: frame rate frazionario, nessun calcolo di frame")
        info.timecodeRate = "25"
        info.timecodeFlag = nil
        XCTAssertEqual(BroadcastWaveMetadataParser.timecode(info), "13:04:57:18")
        info.timeReference = 0
        XCTAssertNil(BroadcastWaveMetadataParser.timecode(info), "time reference zero = non impostato")
        info.timeReference = 90_000 * 48_000
        XCTAssertNil(BroadcastWaveMetadataParser.timecode(info), "oltre 24 ore: non è un'ora del giorno")
    }

    func testFFprobeReadsTheRealRecorderTagsToo() throws {
        let url = fixtures.appendingPathComponent("ffprobe_bwf_zaxcom.json")
        let m = FFprobeMetadataParser.parse(try FFprobeRunner.parse(Data(contentsOf: url)))
        XCTAssertEqual(m["audioCodec"], "PCM")
        XCTAssertEqual(m["audioChannels"], "3")
        XCTAssertEqual(m["audioSampleRate"], "48000")
        XCTAssertEqual(m["audioBitDepth"], "24")
        XCTAssertEqual(m["createDate"], "2026-10-27 13:05:03", "ora con i trattini («13-05-03») riconosciuta")
        XCTAssertNil(m["codec"])
    }

    func testFilesWithoutBWFDataOrNotWAVGiveNothing() throws {
        // WAV minimo: solo fmt + data
        var wav = Data("RIFF".utf8) + le32(36 + 4) + Data("WAVE".utf8)
        wav += Data("fmt ".utf8) + le32(16) + le16(1) + le16(1) + le32(48000) + le32(96000) + le16(2) + le16(16)
        wav += Data("data".utf8) + le32(4) + Data([0, 0, 0, 0])
        let plain = tmp.appendingPathComponent("plain.wav")
        try wav.write(to: plain)
        XCTAssertNil(BroadcastWaveReader.read(path: plain.path))

        let random = tmp.appendingPathComponent("random.wav")
        try TestSupport.writeRandomFile(random, size: 4096, seed: 5)
        XCTAssertNil(BroadcastWaveReader.read(path: random.path), "non è un WAV")
        XCTAssertNil(BroadcastWaveReader.read(path: tmp.appendingPathComponent("manca.wav").path))
    }

    func testIXMLOnlyAndMalformedBlocksAreHandled() throws {
        let xml = "<?xml version=\"1.0\"?><BWFXML><SCENE>12A</SCENE><TAKE>3</TAKE><TRACK_LIST><TRACK><NAME>MIX L</NAME></TRACK><TRACK><NAME>MIX R</NAME></TRACK></TRACK_LIST></BWFXML>\0\0 "
        var wav = Data("RIFF".utf8) + le32(0) + Data("WAVE".utf8)
        wav += Data("iXML".utf8) + le32(UInt32(xml.utf8.count)) + Data(xml.utf8)
        if xml.utf8.count % 2 == 1 { wav += Data([0]) }
        wav += Data("data".utf8) + le32(0)
        let url = tmp.appendingPathComponent("ixml.wav")
        try wav.write(to: url)
        let info = try XCTUnwrap(BroadcastWaveReader.read(path: url.path))
        XCTAssertEqual(info.scene, "12A")
        XCTAssertEqual(info.take, "3")
        XCTAssertEqual(info.trackNames, ["MIX L", "MIX R"])
        XCTAssertNil(info.originator)
        XCTAssertNil(BroadcastWaveMetadataParser.parse(info)["timecode"], "nessun time reference: nessun timecode")
    }

    func testImporterAddsRecorderFieldsToTheFFprobeData() throws {
        guard let probe = FFprobeRunner.locate() else { throw XCTSkip("ffprobe non installato") }
        let card = tmp.appendingPathComponent("CARD", isDirectory: true)
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: header, toPath: card.appendingPathComponent("SPOTIFY_TALKS_04002.wav").path)
        let dest = tmp.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let store = try ProjectStore(path: nil)
        let p = try store.createProject(name: "Film")
        let bin = try store.createBin(parentID: try store.tree(projectID: p.id).id, name: "SOUND")
        let root = dest.appendingPathComponent("SOUND", isDirectory: true)
        let job = OffloadJob(sourceURL: card, destinationRoots: [root], destinationBases: [dest])
        try store.beginOffload(jobID: job.id, binID: bin.id, sourcePath: card.path, destinations: [root.path])
        let result = OffloadEngine(job: job, scan: try SourceScanner.scan(root: card)).run()
        try store.finishOffload(result)
        XCTAssertTrue(result.allOK)

        let clips = try store.clips(forJobID: job.id)
        XCTAssertEqual(clips.count, 1)
        let summary = try MetadataImporter.importMetadata(for: clips, store: store, runner: nil, probe: probe)
        XCTAssertEqual(summary.read, 1, summary.text)
        let m = try XCTUnwrap(try store.clips(underNode: bin.id, mediaOnly: true).first).metadata
        XCTAssertEqual(m["audioChannels"], "3")
        XCTAssertEqual(m["recorder"], "Zaxcom Deva24")
        XCTAssertEqual(m["scene"], "1")
        XCTAssertEqual(m["reel"], "SPOTIFY_TALKS_04")
        XCTAssertEqual(m["trackNames"], "BOOM, RADIO 1, RADIO 2")
        XCTAssertEqual(m["timecode"], "13:04:57:18")
    }

    private func le32(_ v: UInt32) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 4) }
    private func le16(_ v: UInt16) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 2) }
}
