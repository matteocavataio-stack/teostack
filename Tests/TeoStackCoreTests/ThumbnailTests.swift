import XCTest
@testable import TeoStackCore

final class ThumbnailTests: XCTestCase {
    var work: URL!
    var store: ProjectStore!
    var cache: ThumbnailCache!

    override func setUpWithError() throws {
        work = try TestSupport.makeTempDir("thumbs")
        store = try ProjectStore(path: nil)
        cache = ThumbnailCache(directory: work.appendingPathComponent("cache"))
    }

    override func tearDown() { try? FileManager.default.removeItem(at: work) }

    // MARK: Strumenti

    private func realFFmpeg() throws -> FFmpegRunner {
        guard let path = ExternalTools.detect(.ffmpeg).path else { throw XCTSkip("ffmpeg non installato") }
        return FFmpegRunner(executable: path)
    }

    /// Video ProRes reale di 1 secondo (640x360) creato con ffmpeg.
    private func makeProResClip(at url: URL, width: Int = 640, height: Int = 360) throws {
        let ffmpeg = try realFFmpeg()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg.executable)
        p.arguments = ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=duration=1:size=\(width)x\(height):rate=24",
                       "-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le", url.path]
        p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw XCTSkip("questo ffmpeg non sa creare file ProRes di prova") }
    }

    /// Dimensioni di un JPEG leggendo il marcatore SOF.
    private func jpegSize(_ url: URL) throws -> (width: Int, height: Int) {
        let b = [UInt8](try Data(contentsOf: url))
        XCTAssertEqual(Array(b.prefix(2)), [0xFF, 0xD8], "non è un JPEG")
        var i = 2
        while i + 9 < b.count {
            guard b[i] == 0xFF else { i += 1; continue }
            let marker = b[i + 1]
            if [0xC0, 0xC1, 0xC2].contains(marker) { return (Int(b[i + 7]) << 8 | Int(b[i + 8]), Int(b[i + 5]) << 8 | Int(b[i + 6])) }
            i += 2 + (Int(b[i + 2]) << 8 | Int(b[i + 3]))
        }
        throw XCTSkip("SOF non trovato")
    }

    private func script(_ body: String, name: String = UUID().uuidString) throws -> String {
        let url = work.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private var tiffFixture: String { Fixtures.directory.appendingPathComponent("art_cmd_frame_rgb16.tif").path }

    /// Finto art-cmd: scrive il TIFF di prova dove indica --output (modello "%07d.tif" → 0000000.tif) e registra gli argomenti.
    private func fakeArt(log: String? = nil, failWhenEmbeddedLook: Bool = false, alwaysFail: Bool = false) throws -> ARTCmdRunner {
        let logLine = log.map { "echo \"$@\" >> '\($0)'" } ?? ""
        return ARTCmdRunner(executable: try script("""
        \(logLine)
        out=""; look=0
        while [ $# -gt 0 ]; do
          if [ "$1" = "--output" ]; then out="$2"; fi
          if [ "$1" = "--embedded-look" ]; then look=1; fi
          shift
        done
        \(alwaysFail ? "echo 'Unsupported input format' >&2; exit 3" : "")
        \(failWhenEmbeddedLook ? "if [ $look = 1 ]; then echo 'look not supported' >&2; exit 2; fi" : "")
        dir=$(dirname "$out")
        cp '\(tiffFixture)' "$dir/0000000.tif"
        """))
    }

    private func clip(id: Int64 = 1, name: String = "clip.mov", camera: String? = nil) -> ClipRecord {
        ClipRecord(id: id, offloadID: 1, binID: 1, relativePath: name, name: name, size: 1, sourceHash: "x", status: "ok",
                   destinationStatuses: ["ok"], isMedia: true, metadata: camera.map { ["camera": $0] } ?? [:],
                   offloadDate: Date(), binName: "b", dayName: "d")
    }

    // MARK: ffmpeg

    func testFFmpegExtractsFirstFrameOfRealProResClip() throws {
        let ffmpeg = try realFFmpeg()
        let video = work.appendingPathComponent("v/clip.mov")
        try makeProResClip(at: video)
        let out = work.appendingPathComponent("t.jpg")
        try ffmpeg.extractFirstFrame(from: video.path, to: out.path, maxWidth: 320)
        let size = try jpegSize(out)
        XCTAssertEqual(size.width, 320)
        XCTAssertEqual(size.height, 180)
    }

    func testFFmpegDoesNotUpscale() throws {
        let ffmpeg = try realFFmpeg()
        let video = work.appendingPathComponent("small.mov")
        try makeProResClip(at: video, width: 160, height: 90)
        let out = work.appendingPathComponent("t.jpg")
        try ffmpeg.extractFirstFrame(from: video.path, to: out.path, maxWidth: 640)
        XCTAssertEqual(try jpegSize(out).width, 160)
    }

    func testFFmpegReportsErrorForGarbageAndLeavesNoFile() throws {
        let ffmpeg = try realFFmpeg()
        let garbage = work.appendingPathComponent("garbage.mxf")
        try TestSupport.writeRandomFile(garbage, size: 50_000, seed: 3)
        let out = work.appendingPathComponent("t.jpg")
        XCTAssertThrowsError(try ffmpeg.extractFirstFrame(from: garbage.path, to: out.path, maxWidth: 320)) { error in
            XCTAssertTrue("\(error)".contains("ffmpeg non ha estratto il fotogramma"), "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
        XCTAssertThrowsError(try FFmpegRunner(executable: "/nonexistent/ffmpeg").extractFirstFrame(from: garbage.path, to: out.path, maxWidth: 320))
    }

    // MARK: Generatore

    func testGenerateNonARRIClipWithFFmpeg() throws {
        let ffmpeg = try realFFmpeg()
        let video = work.appendingPathComponent("v/clip.mov")
        try makeProResClip(at: video)
        try ThumbnailGenerator.generate(clip: clip(id: 7), file: video.path, tools: ThumbnailTools(art: nil, ffmpeg: ffmpeg), cache: cache)
        XCTAssertTrue(cache.hasImage(clipID: 7))
        XCTAssertEqual(try jpegSize(cache.imageURL(clipID: 7)).width, 640)
        XCTAssertNil(cache.failureReason(clipID: 7))
    }

    func testARRIClipUsesArtCmdProcessFirstFrame() throws {
        let ffmpeg = try? realFFmpeg()
        #if !canImport(ImageIO)
        guard ffmpeg != nil else { throw XCTSkip("serve ffmpeg per convertire il TIFF su questa piattaforma") }
        #endif
        let log = work.appendingPathComponent("args.log").path
        let art = try fakeArt(log: log)
        try ThumbnailGenerator.generate(clip: clip(id: 1, name: "DW0001C021.mxf", camera: "ARRI ALEXA 35"), file: "/Volumes/X/DW0001C021.mxf",
                                        tools: ThumbnailTools(art: art, ffmpeg: ffmpeg), cache: cache)
        XCTAssertTrue(cache.hasImage(clipID: 1))
        let size = try jpegSize(cache.imageURL(clipID: 1))
        XCTAssertEqual(size.width, 64, "l'immagine di prova è 64x36 e non viene ingrandita")
        let args = try String(contentsOfFile: log)
        XCTAssertTrue(args.hasPrefix("process --input /Volumes/X/DW0001C021.mxf --start 0 --duration 1 --embedded-look --target-colorspace Rec.709/D65/BT.1886 --output "), args)
        XCTAssertTrue(args.contains("%07d.tif"))
    }

    func testArtCmdFallsBackToRenderWithoutLookWhenLookFails() throws {
        let ffmpeg = try? realFFmpeg()
        #if !canImport(ImageIO)
        guard ffmpeg != nil else { throw XCTSkip("serve ffmpeg per convertire il TIFF su questa piattaforma") }
        #endif
        let log = work.appendingPathComponent("args.log").path
        let art = try fakeArt(log: log, failWhenEmbeddedLook: true)
        try ThumbnailGenerator.generate(clip: clip(camera: "ARRI ALEXA 35"), file: "/x.mxf", tools: ThumbnailTools(art: art, ffmpeg: ffmpeg), cache: cache)
        XCTAssertTrue(cache.hasImage(clipID: 1))
        let lines = try String(contentsOfFile: log).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("--embedded-look") && !lines[1].contains("--embedded-look"))
    }

    func testARRIClipFallsBackToFFmpegWhenArtCmdFails() throws {
        let ffmpeg = try realFFmpeg()
        let video = work.appendingPathComponent("v/arri_prores.mov")
        try makeProResClip(at: video)
        let art = try fakeArt(alwaysFail: true)
        try ThumbnailGenerator.generate(clip: clip(camera: "ARRI ALEXA Mini"), file: video.path, tools: ThumbnailTools(art: art, ffmpeg: ffmpeg), cache: cache)
        XCTAssertTrue(cache.hasImage(clipID: 1))
    }

    func testUndecodableClipRecordsTheReasonAndNeverFakesAnImage() throws {
        let ffmpeg = try realFFmpeg()
        let garbage = work.appendingPathComponent("raw.mxf")
        try TestSupport.writeRandomFile(garbage, size: 50_000, seed: 9)
        let art = try fakeArt(alwaysFail: true)
        XCTAssertThrowsError(try ThumbnailGenerator.generate(clip: clip(camera: "ARRI ALEXA 35"), file: garbage.path,
                                                             tools: ThumbnailTools(art: art, ffmpeg: ffmpeg), cache: cache)) { error in
            let text = "\(error)"
            XCTAssertTrue(text.contains("non decodificabile"), text)
            XCTAssertTrue(text.contains("art-cmd") && text.contains("Unsupported input format"), text)
            XCTAssertTrue(text.contains("ffmpeg"), text)
        }
        XCTAssertFalse(cache.hasImage(clipID: 1))
        XCTAssertEqual(cache.failureReason(clipID: 1)?.contains("art-cmd"), true)
    }

    func testARRIClipWithoutArtCmdSaysItNeedsIt() throws {
        let garbage = work.appendingPathComponent("raw.mxf")
        try TestSupport.writeRandomFile(garbage, size: 5_000, seed: 1)
        XCTAssertThrowsError(try ThumbnailGenerator.generate(clip: clip(camera: "ARRI ALEXA 35"), file: garbage.path,
                                                             tools: ThumbnailTools(art: nil, ffmpeg: nil), cache: cache)) { error in
            XCTAssertTrue("\(error)".contains("serve art-cmd"), "\(error)")
        }
        XCTAssertTrue(cache.failureReason(clipID: 1)?.contains("ffmpeg non installato") == true)
    }

    func testSuccessClearsPreviousFailure() throws {
        let ffmpeg = try realFFmpeg()
        let video = work.appendingPathComponent("v/clip.mov")
        try makeProResClip(at: video)
        let garbage = work.appendingPathComponent("g.mov")
        try TestSupport.writeRandomFile(garbage, size: 5_000, seed: 2)
        XCTAssertThrowsError(try ThumbnailGenerator.generate(clip: clip(), file: garbage.path, tools: ThumbnailTools(art: nil, ffmpeg: ffmpeg), cache: cache))
        XCTAssertNotNil(cache.failureReason(clipID: 1))
        try ThumbnailGenerator.generate(clip: clip(), file: video.path, tools: ThumbnailTools(art: nil, ffmpeg: ffmpeg), cache: cache)
        XCTAssertNil(cache.failureReason(clipID: 1))
        XCTAssertTrue(cache.hasImage(clipID: 1))
        cache.remove(clipID: 1)
        XCTAssertFalse(cache.hasImage(clipID: 1))
    }

    // MARK: Importazione dei clip di un bin

    private func offloadedClips() throws -> (clips: [ClipRecord], dest: URL) {
        let card = work.appendingPathComponent("CARD", isDirectory: true)
        try makeProResClip(at: card.appendingPathComponent("A001/good.mov"))
        try TestSupport.writeRandomFile(card.appendingPathComponent("A001/bad.mxf"), size: 30_000, seed: 5)
        try TestSupport.writeRandomFile(card.appendingPathComponent("A001/notes.xml"), size: 100, seed: 6)
        let p = try store.createProject(name: "Film")
        let bin = try store.createBin(dayID: try store.createDay(projectID: p.id, name: "D1").id, name: "a001")
        let dest = work.appendingPathComponent("out/a001")
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let job = OffloadJob(sourceURL: card, destinationRoots: [dest])
        try store.beginOffload(jobID: job.id, binID: bin.id, sourcePath: card.path, destinations: [dest.path])
        let result = OffloadEngine(job: job, scan: try SourceScanner.scan(root: card)).run()
        XCTAssertTrue(result.allOK)
        try store.finishOffload(result)
        return (try store.clips(underNode: bin.id), dest)
    }

    func testImporterGeneratesSkipsExistingAndReportsFailures() throws {
        let ffmpeg = try realFFmpeg()
        let (clips, _) = try offloadedClips()
        XCTAssertEqual(clips.count, 2, "good.mov e bad.mxf (l'XML non è un clip)")
        let tools = ThumbnailTools(art: nil, ffmpeg: ffmpeg)

        let first = try ThumbnailGenerator.generate(for: clips, store: store, tools: tools, cache: cache)
        XCTAssertEqual(first.generated, 1)
        XCTAssertEqual(first.failed.count, 1)
        XCTAssertTrue(first.failed[0].hasPrefix("bad.mxf: "))
        let good = try XCTUnwrap(clips.first { $0.name == "good.mov" }), bad = try XCTUnwrap(clips.first { $0.name == "bad.mxf" })
        XCTAssertTrue(cache.hasImage(clipID: good.id))
        XCTAssertFalse(cache.hasImage(clipID: bad.id))
        XCTAssertNotNil(cache.failureReason(clipID: bad.id))

        let second = try ThumbnailGenerator.generate(for: clips, store: store, tools: tools, cache: cache)
        XCTAssertEqual(second.alreadyPresent, 1)
        XCTAssertEqual(second.generated, 0)
        XCTAssertEqual(second.failed.count, 1, "il clip non decodificabile viene ritentato")

        let forced = try ThumbnailGenerator.generate(for: clips, store: store, tools: tools, cache: cache, regenerate: true)
        XCTAssertEqual(forced.generated, 1)
        XCTAssertTrue(first.text.contains("1 anteprime create") && first.text.contains("1 non decodificabili"))
    }

    func testImporterSkipsMissingDestinationFile() throws {
        let ffmpeg = try realFFmpeg()
        let (clips, dest) = try offloadedClips()
        try FileManager.default.removeItem(at: dest.appendingPathComponent("A001/good.mov"))
        let s = try ThumbnailGenerator.generate(for: clips, store: store, tools: ThumbnailTools(art: nil, ffmpeg: ffmpeg), cache: cache)
        XCTAssertEqual(s.missingFile, 1)
        XCTAssertEqual(s.generated, 0)
    }

    func testImporterNeedsAtLeastOneTool() throws {
        XCTAssertThrowsError(try ThumbnailGenerator.generate(for: [], store: store, tools: ThumbnailTools(art: nil, ffmpeg: nil), cache: cache)) { error in
            guard case MetadataError.toolMissing = error else { return XCTFail("\(error)") }
        }
    }

    func testFFmpegIsDetectedAndHasInstructions() {
        XCTAssertEqual(ExternalTool.ffmpeg.executableName, "ffmpeg")
        XCTAssertFalse(ExternalTool.ffmpeg.isRequired)
        XCTAssertTrue(ExternalTool.ffmpeg.installInstructions.contains("ffmpeg-9.0.2.zip"))
    }
}
