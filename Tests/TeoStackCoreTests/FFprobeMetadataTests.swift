import XCTest
@testable import TeoStackCore

/// Metadata dei formati senza parser dedicato (MPG, WAV/BWF, LRF/MP4, ProRes) letti con ffprobe.
/// I JSON in Fixtures sono output veri di ffprobe: `ffprobe_mpeg2_ac3.json` viene dal file MPG di prova dell'utente (MPEG-2 PS, AC-3);
/// gli altri da file generati con ffmpeg (non sono registrazioni di una camera DJI o di un registratore reale).
final class FFprobeMetadataTests: XCTestCase {
    private func fixture(_ name: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
        return try FFprobeRunner.parse(Data(contentsOf: url))
    }

    func testMPEG2ProgramStreamWithAC3Audio() throws {
        let m = FFprobeMetadataParser.parse(try fixture("ffprobe_mpeg2_ac3.json"))
        XCTAssertEqual(m["codec"], "MPEG-2 Main")
        XCTAssertEqual(m["resolution"], "720x480")
        XCTAssertEqual(m["frameRate"], "29.97")
        XCTAssertEqual(m["durationSeconds"], "4.505")
        XCTAssertEqual(m["audioCodec"], "AC-3", "ExifTool lo darebbe come MPEG layer 3: ffprobe dice AC-3")
        XCTAssertEqual(m["audioChannels"], "2")
        XCTAssertEqual(m["audioSampleRate"], "48000", "ExifTool darebbe 0")
        // il file non dichiara questi dati: non si inventano
        for key in ["audioBitDepth", "timecode", "createDate", "camera", "manufacturer", "firmware", "lens", "iso"] {
            XCTAssertNil(m[key], key)
        }
    }

    func testPlainWavHasOnlyAudioData() throws {
        let m = FFprobeMetadataParser.parse(try fixture("ffprobe_wav_pcm24.json"))
        XCTAssertEqual(m["audioCodec"], "PCM")
        XCTAssertEqual(m["audioChannels"], "2")
        XCTAssertEqual(m["audioSampleRate"], "48000")
        XCTAssertEqual(m["audioBitDepth"], "24")
        XCTAssertEqual(m["durationSeconds"], "2")
        for key in ["codec", "resolution", "frameRate", "timecode", "createDate"] { XCTAssertNil(m[key], key) }
    }

    func testBroadcastWaveDateAndTimeReference() throws {
        let m = FFprobeMetadataParser.parse(try fixture("ffprobe_bwf.json"))
        XCTAssertEqual(m["createDate"], "2026-10-27 03:18:54", "data e ora del BWF (nessun fuso nel file: non se ne inventa uno)")
        // time_reference = 1 000 000 000 campioni a 48 kHz = 20833,333 s dalla mezzanotte
        XCTAssertEqual(m["timecode"], "05:47:13.333")
        XCTAssertEqual(m["audioBitDepth"], "24")
    }

    func testMP4LikeLRFProxy() throws {
        let m = FFprobeMetadataParser.parse(try fixture("ffprobe_mp4_h264_aac.json"))
        XCTAssertEqual(m["codec"], "H.264 High")
        XCTAssertEqual(m["resolution"], "1280x720")
        XCTAssertEqual(m["frameRate"], "29.97")
        XCTAssertEqual(m["durationSeconds"], "2.002")
        XCTAssertEqual(m["audioCodec"], "AAC LC")
        XCTAssertEqual(m["audioChannels"], "1")
        XCTAssertEqual(m["createDate"], "2026-10-27 03:18:54 UTC", "il file dichiara UTC («Z»): lo si scrive")
        XCTAssertNil(m["audioBitDepth"], "AAC non ha una profondità in bit")
        XCTAssertNil(m["camera"], "il file non dice quale camera l'ha creato")
    }

    func testProResKeepsTheTimecodeWrittenInTheFile() throws {
        let m = FFprobeMetadataParser.parse(try fixture("ffprobe_prores_timecode.json"))
        XCTAssertEqual(m["codec"], "ProRes HQ")
        XCTAssertEqual(m["resolution"], "1920x1080")
        XCTAssertEqual(m["frameRate"], "24")
        XCTAssertEqual(m["timecode"], "01:02:03:04")
        XCTAssertNil(m["audioCodec"], "nessuna traccia audio nel file")
    }

    func testCameraTagsAreReadOnlyWhenPresentAndDatesAreNeverInvented() {
        let json: [String: Any] = [
            "streams": [["codec_type": "video", "codec_name": "hevc", "profile": "Main 10", "width": 3840, "height": 2160,
                         "avg_frame_rate": "25/1", "tags": ["timecode": "10:00:00;02"]]],
            "format": ["duration": "12.5", "tags": ["com.apple.quicktime.make": "Apple", "com.apple.quicktime.model": "iPhone 15 Pro",
                                                   "creation_time": "2026-10-27T05:18:54+0200"]],
        ]
        let m = FFprobeMetadataParser.parse(json)
        XCTAssertEqual(m["manufacturer"], "Apple")
        XCTAssertEqual(m["camera"], "iPhone 15 Pro")
        XCTAssertEqual(m["codec"], "H.265 (HEVC) Main 10")
        XCTAssertEqual(m["createDate"], "2026-10-27 05:18:54 +02:00")
        XCTAssertEqual(m["timecode"], "10:00:00;02", "il drop-frame si riporta com'è scritto nel file")

        // data illeggibile o timecode malformato: assenti, non corretti a caso
        let bad = FFprobeMetadataParser.parse(["streams": [["codec_type": "video", "codec_name": "h264", "tags": ["timecode": "boh"]]],
                                               "format": ["tags": ["creation_time": "ieri sera"]]])
        XCTAssertNil(bad["createDate"])
        XCTAssertNil(bad["timecode"])
        XCTAssertEqual(FFprobeMetadataParser.parse([:]), [:], "senza dati non si scrive nulla")
    }

    func testCoverArtIsNotAVideoAndMultiMonoAudioTracksAreSummed() {
        let json: [String: Any] = [
            "streams": [
                ["codec_type": "audio", "codec_name": "pcm_s24le", "channels": 1, "sample_rate": "48000", "bits_per_sample": 24],
                ["codec_type": "audio", "codec_name": "pcm_s24le", "channels": 1, "sample_rate": "48000", "bits_per_sample": 24],
                ["codec_type": "video", "codec_name": "mjpeg", "width": 500, "height": 500, "disposition": ["attached_pic": 1]],
            ],
            "format": ["duration": "3.0"],
        ]
        let m = FFprobeMetadataParser.parse(json)
        XCTAssertNil(m["codec"], "la copertina allegata non è il video")
        XCTAssertNil(m["resolution"])
        XCTAssertEqual(m["audioChannels"], "2")
        XCTAssertEqual(m["audioCodec"], "PCM")
        XCTAssertEqual(m["audioSampleRate"], "48000")
    }
}

final class FormatClassificationTests: XCTestCase {
    func testNewFormatsAndAppleDoubleFiles() {
        for path in ["A001/M2U00001.MPG", "x/clip.mpeg", "DCIM/DJI_0001_D.LRF", "a.mov", "a.MXF"] {
            XCTAssertTrue(MediaClassifier.isMedia(relativePath: path), path)
            XCTAssertFalse(MediaClassifier.isAudio(relativePath: path), path)
        }
        for path in ["SOUND/T2_04002.wav", "a.BWF", "b.flac"] {
            XCTAssertTrue(MediaClassifier.isAudio(relativePath: path), path)
            XCTAssertFalse(MediaClassifier.isMedia(relativePath: path), path)
        }
        // «._nome»: file di servizio di macOS (solo attributi), non clip anche se finisce con .mov/.wav/.lrf
        for path in ["._DJI_0001_D.LRF", "A001/._A001C001.mov", "SOUND/._T2_04002.wav"] {
            XCTAssertTrue(MediaClassifier.isAppleDouble(relativePath: path), path)
            XCTAssertFalse(MediaClassifier.isMedia(relativePath: path), path)
            XCTAssertFalse(MediaClassifier.isAudio(relativePath: path), path)
        }
        XCTAssertFalse(MediaClassifier.isMedia(relativePath: "notes.txt"))
    }
}

final class AudioClipsStoreTests: XCTestCase {
    private var card: URL!
    private var dest: URL!

    override func setUpWithError() throws {
        card = try TestSupport.makeTempDir("fmtcard").appendingPathComponent("D001", isDirectory: true)
        dest = try TestSupport.makeTempDir("fmtdest")
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        for (i, name) in ["V/M2U00001.MPG", "V/DJI_0001_D.LRF", "V/._DJI_0001_D.LRF", "A/T2_04002.wav", "A/._T2_04002.wav", "V/notes.txt"].enumerated() {
            try TestSupport.writeRandomFile(card.appendingPathComponent(name), size: 5_000 + i, seed: UInt64(i + 1))
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: card.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: dest)
    }

    private func offload(into store: ProjectStore) throws -> (Project, TreeNode) {
        let p = try store.createProject(name: "Film")
        let bin = try store.createBin(parentID: try store.tree(projectID: p.id).id, name: "D001")
        let root = dest.appendingPathComponent("D001", isDirectory: true)
        let job = OffloadJob(sourceURL: card, destinationRoots: [root], destinationBases: [dest])
        try store.beginOffload(jobID: job.id, binID: bin.id, sourcePath: card.path, destinations: [root.path])
        let result = OffloadEngine(job: job, scan: try SourceScanner.scan(root: card)).run()
        XCTAssertTrue(result.allOK, "anche i file «._» vengono copiati e verificati come tutti gli altri")
        try store.finishOffload(result)
        return (p, bin)
    }

    func testClipsAreClassifiedAndAudioIsListedButNotCountedAsVideo() throws {
        let store = try ProjectStore(path: nil)
        let (p, bin) = try offload(into: store)

        let all = try store.clips(underNode: bin.id, mediaOnly: false)
        XCTAssertEqual(all.count, 6, "tutti i file sono registrati")
        let shown = try store.clips(underNode: bin.id, mediaOnly: true).map(\.name).sorted()
        XCTAssertEqual(shown, ["DJI_0001_D.LRF", "M2U00001.MPG", "T2_04002.wav"], "video e audio veri, senza i file «._» né il testo")
        XCTAssertEqual(all.first { $0.name == "T2_04002.wav" }?.isAudio, true)
        XCTAssertEqual(all.first { $0.name == "._T2_04002.wav" }?.isAudio, false)
        XCTAssertEqual(all.first { $0.name == "._DJI_0001_D.LRF" }?.isMedia, false)
        XCTAssertEqual(try store.projects().first { $0.id == p.id }?.clipCount, 2, "il conteggio clip resta video: MPG + LRF")

        let recap = try store.recap(underNode: bin.id)
        XCTAssertEqual(recap.clipCount, 2)
        XCTAssertEqual(recap.audioCount, 1)
        XCTAssertEqual(recap.fileCount, 6)
        XCTAssertEqual(recap.audioWithoutFormat, 1, "metadata non ancora letti")
    }

    func testMigrationReclassifiesClipsRegisteredBeforeTheNewFormats() throws {
        let path = try TestSupport.makeTempDir("fmtdb").appendingPathComponent("teostack.sqlite").path
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        var store: ProjectStore? = try ProjectStore(path: path)
        let (_, bin) = try offload(into: try XCTUnwrap(store))

        // riporta il database allo schema precedente: senza isAudio, con le vecchie regole (solo mov/mxf/mp4/ari, «._» incluso)
        try XCTUnwrap(store).executeRaw("DELETE FROM grdb_migrations WHERE identifier = 'v6-audio-and-more-formats'")
        try XCTUnwrap(store).executeRaw("ALTER TABLE clip DROP COLUMN isAudio")
        try XCTUnwrap(store).executeRaw("UPDATE clip SET isMedia = CASE WHEN lower(name) LIKE '%.lrf' OR lower(name) LIKE '%.mpg' THEN 0 ELSE isMedia END")
        store = nil

        let reopened = try ProjectStore(path: path)
        let all = try reopened.clips(underNode: bin.id, mediaOnly: false)
        XCTAssertEqual(all.count, 6, "nessun file perso nella migrazione")
        XCTAssertEqual(Set(try reopened.clips(underNode: bin.id, mediaOnly: true).map(\.name)), ["DJI_0001_D.LRF", "M2U00001.MPG", "T2_04002.wav"])
        XCTAssertEqual(all.first { $0.name == "T2_04002.wav" }?.isAudio, true)
        XCTAssertEqual(all.first { $0.name == "M2U00001.MPG" }?.isMedia, true)
    }

    /// Prova completa con ffprobe/ffmpeg veri, se installati (altrimenti saltata): copia verificata → lettura metadata → valori salvati.
    func testRealFilesAreOffloadedAndTheirMetadataIsRead() throws {
        guard let probe = FFprobeRunner.locate(), let ffmpeg = FFmpegRunner.locate().map(\.executable) else {
            throw XCTSkip("ffprobe/ffmpeg non installati")
        }
        func make(_ args: [String], _ out: String) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ffmpeg)
            p.arguments = ["-v", "error", "-y"] + args + [card.appendingPathComponent(out).path]
            try p.run(); p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, out)
        }
        // sostituisce i file casuali con media veri
        for f in ["V/M2U00001.MPG", "V/DJI_0001_D.LRF", "A/T2_04002.wav"] { try FileManager.default.removeItem(at: card.appendingPathComponent(f)) }
        try make(["-f", "lavfi", "-i", "testsrc=size=720x480:rate=30000/1001:duration=1", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=1",
                  "-c:v", "mpeg2video", "-c:a", "ac3", "-f", "mpeg"], "V/M2U00001.MPG")
        try make(["-f", "lavfi", "-i", "testsrc=size=640x360:rate=25:duration=1", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-f", "mp4"], "V/DJI_0001_D.LRF")
        try make(["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=1", "-c:a", "pcm_s16le", "-f", "wav"], "A/T2_04002.wav")

        let store = try ProjectStore(path: nil)
        let (_, bin) = try offload(into: store)
        let clips = try store.clips(underNode: bin.id, mediaOnly: true)
        XCTAssertEqual(clips.count, 3)
        let summary = try MetadataImporter.importMetadata(for: clips, store: store, runner: nil, probe: probe)
        XCTAssertEqual(summary.read, 3, summary.text)
        XCTAssertEqual(summary.unsupported, 0)

        let byName = Dictionary(uniqueKeysWithValues: try store.clips(underNode: bin.id, mediaOnly: true).map { ($0.name, $0.metadata) })
        XCTAssertEqual(byName["M2U00001.MPG"]?["codec"], "MPEG-2 Main")
        XCTAssertEqual(byName["M2U00001.MPG"]?["resolution"], "720x480")
        XCTAssertEqual(byName["M2U00001.MPG"]?["audioCodec"], "AC-3")
        XCTAssertEqual(byName["DJI_0001_D.LRF"]?["codec"], "H.264 High")
        XCTAssertEqual(byName["DJI_0001_D.LRF"]?["frameRate"], "25")
        XCTAssertEqual(byName["T2_04002.wav"]?["audioSampleRate"], "44100")
        XCTAssertEqual(byName["T2_04002.wav"]?["audioBitDepth"], "16")
        XCTAssertNil(byName["T2_04002.wav"]?["resolution"])

        let recap = try store.recap(underNode: bin.id)
        XCTAssertEqual(recap.clipCount, 2)
        XCTAssertEqual(recap.audioCount, 1)
        XCTAssertEqual(recap.clipsWithDuration, 2, "la durata dell'audio non si somma ai clip video")
        XCTAssertTrue(recap.formats.contains { $0.label == "MPEG-2 Main · 720x480 · .MPG" && !$0.isAudio })
        XCTAssertTrue(recap.formats.contains { $0.label == "PCM · 16 bit · 44100 Hz · .WAV" && $0.isAudio })
    }
}
