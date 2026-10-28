import XCTest
@testable import TeoStackCore

/// Prove su file veri prodotti con ffmpeg (contenitori reali, senza metadata di camera) e ExifTool (che scrive i tag EXIF/QuickTime nel file temporaneo del test).
/// Servono ffmpeg ed ExifTool installati; altrimenti i test si saltano.
final class CameraFamilyReaderTests: XCTestCase {
    private var dir: URL!
    private let tools = ReaderTools.detect()

    override func setUpWithError() throws {
        dir = try TestSupport.makeTempDir("camera-family")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func run(_ exe: String, _ args: [String]) throws {
        let candidates = ["/usr/bin/\(exe)", "/usr/local/bin/\(exe)", "/opt/homebrew/bin/\(exe)"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw XCTSkip("\(exe) non installato") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "\(exe) \(args.joined(separator: " "))")
    }

    private func ffmpeg(_ args: [String]) throws { try run("ffmpeg", ["-v", "error", "-y"] + args) }
    private func exiftoolWrite(_ args: [String], _ file: URL) throws { try run("exiftool", ["-overwrite_original"] + args + [file.path]) }

    private func needTools() throws {
        guard tools.exiftool != nil, tools.ffprobe != nil else { throw XCTSkip("ExifTool e ffprobe servono a questi test") }
    }

    private func read(_ file: URL) -> ClipMetadata { ReaderRegistry.standard().read(url: file, tools: tools) }

    // MARK: MP4/MOV con costruttore dichiarato (QuickTime Keys)

    func testMP4DeclaringSonyIsRoutedToTheSonyReaderAndTechnicalDataComesFromFFprobe() throws {
        try needTools()
        let f = dir.appendingPathComponent("C0001.MP4")
        try ffmpeg(["-f", "lavfi", "-i", "testsrc=size=320x180:rate=25", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "1",
                    "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-movflags", "use_metadata_tags",
                    "-metadata", "make=SONY", "-metadata", "model=ILCE-7SM3", f.path])
        let m = read(f)
        XCTAssertEqual(m.family, "Sony")
        XCTAssertEqual(m.cameraMake, "SONY")
        XCTAssertEqual(m.cameraModel, "ILCE-7SM3")
        XCTAssertEqual(m.width, 320); XCTAssertEqual(m.height, 180)
        XCTAssertEqual(m.fps, 25)
        XCTAssertEqual(m.container, "MP4")
        XCTAssertEqual(m.audioSampleRate, 48000)
        XCTAssertNotNil(m.duration)
        XCTAssertNil(m.cameraSerial, "il file non lo dichiara: resta vuoto")
        XCTAssertNil(m.iso)
        XCTAssertEqual(m.rawFields["Keys:Make"], "SONY")
    }

    func testSameFileWithAnotherMakeGoesToAnotherFamily() throws {
        try needTools()
        for (make, family) in [("Canon", "Canon"), ("Panasonic", "Panasonic"), ("Blackmagic Design", "Blackmagic")] {
            let f = dir.appendingPathComponent("clip-\(family).mov")
            try ffmpeg(["-f", "lavfi", "-i", "testsrc=size=64x48:rate=24", "-t", "1", "-c:v", "mpeg4", "-movflags", "use_metadata_tags", "-metadata", "make=\(make)", f.path])
            XCTAssertEqual(read(f).family, family, make)
        }
    }

    func testMP4WithoutVendorIsGenericAndNothingIsInvented() throws {
        try needTools()
        let f = dir.appendingPathComponent("plain.mp4")
        try ffmpeg(["-f", "lavfi", "-i", "testsrc=size=64x48:rate=30", "-t", "1", "-c:v", "libx264", "-pix_fmt", "yuv420p", f.path])
        let m = read(f)
        XCTAssertEqual(m.family, "Generic")
        XCTAssertNil(m.cameraMake); XCTAssertNil(m.cameraModel); XCTAssertNil(m.iso); XCTAssertNil(m.lensModel)
        XCTAssertEqual(m.width, 64)
    }

    // MARK: MXF e MPEG-TS reali

    func testRealMXFContainerFromFFmpegIsReadWithoutVendor() throws {
        try needTools()
        let f = dir.appendingPathComponent("clip.mxf")
        try ffmpeg(["-f", "lavfi", "-i", "testsrc=size=320x180:rate=25", "-t", "1", "-c:v", "mpeg2video", "-f", "mxf", f.path])
        XCTAssertEqual(FileProbe(url: f).kind, .mxf)
        let m = read(f)
        XCTAssertEqual(m.status, .read)
        XCTAssertEqual(m.container, "MXF")
        XCTAssertEqual(m.width, 320)
        XCTAssertNil(m.cameraMake, "ApplicationSupplierName («FFmpeg») è il software, non la camera")
        XCTAssertNil(m.creationDate, "la data 0000:00:00 non è una data")
        XCTAssertEqual(m.timecodeStart, "00:00:00:00")
    }

    func testRealMPEGTransportStream() throws {
        try needTools()
        let f = dir.appendingPathComponent("00001.MTS")
        try ffmpeg(["-f", "lavfi", "-i", "testsrc=size=320x180:rate=25", "-t", "1", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-f", "mpegts", f.path])
        XCTAssertEqual(FileProbe(url: f).kind, .mpegTransport)
        let m = read(f)
        XCTAssertEqual(m.status, .read)
        XCTAssertEqual(m.width, 320)
        XCTAssertEqual(m.container, "AVCHD/MPEG-TS")
    }

    // MARK: Foto e sequenze (EXIF)

    func testJPEGExifFieldsAreMappedAndFormatted() throws {
        try needTools()
        let f = dir.appendingPathComponent("IMG_0001.JPG")
        try ffmpeg(["-f", "lavfi", "-i", "testsrc=size=64x48", "-frames:v", "1", f.path])
        try exiftoolWrite(["-Make=Canon", "-Model=EOS R5", "-ISO=800", "-FNumber=2.8", "-FocalLength=35", "-LensModel=RF35mm",
                           "-ExposureTime=0.02", "-DateTimeOriginal=2026:10:28 10:11:12"], f)
        let m = read(f)
        XCTAssertEqual(m.family, "Generic (Canon)", "le foto non hanno un lettore di famiglia: lettore generico, costruttore dichiarato")
        XCTAssertEqual(m.cameraMake, "Canon")
        XCTAssertEqual(m.cameraModel, "EOS R5")
        XCTAssertEqual(m.iso, "800")
        XCTAssertEqual(m.aperture, "2.8")
        XCTAssertEqual(m.focalLength, "35 mm")
        XCTAssertEqual(m.lensModel, "RF35mm")
        XCTAssertEqual(m.shutter, "1/50")
        XCTAssertEqual(m.creationDate, "2026-10-28 10:11:12")
        XCTAssertEqual(m.width, 64); XCTAssertEqual(m.height, 48)
        XCTAssertNil(m.duration, "una foto non ha durata")
        XCTAssertNil(m.fps)
        XCTAssertEqual(m.container, "JPEG")
    }

    func testDPXFrameHasSizeButNoInventedDurationOrFrameRate() throws {
        try needTools()
        let f = dir.appendingPathComponent("A001.00000001.dpx")
        try ffmpeg(["-f", "lavfi", "-i", "testsrc=size=64x48", "-frames:v", "1", f.path])
        let m = read(f)
        XCTAssertEqual(m.container, "DPX")
        XCTAssertEqual(m.width, 64)
        XCTAssertNil(m.duration); XCTAssertNil(m.fps)
    }

    // MARK: Sidecar XML (Sony NonRealTimeMeta, formato dichiarato; non verificato su camere vere)

    func testSonyStyleSidecarFillsMissingFieldsAndIsReadOnly() throws {
        try needTools()
        let clips = dir.appendingPathComponent("CLIP", isDirectory: true)
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        let f = clips.appendingPathComponent("C0007.MP4")
        try ffmpeg(["-f", "lavfi", "-i", "testsrc=size=320x180:rate=25", "-t", "1", "-c:v", "libx264", "-pix_fmt", "yuv420p", f.path])
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <NonRealTimeMeta xmlns="urn:schemas-professionalDisc:nonRealTimeMeta:ver.2.00">
          <CreationDate value="2026-10-28T10:11:12+01:00"/>
          <Device manufacturer="Sony" modelName="ILME-FX3" serialNo="1234567"/>
          <VideoFrame videoCodec="AVC_3840_2160_HP@L51" captureFps="23.98p" formatFps="23.98p"/>
        </NonRealTimeMeta>
        """
        try xml.write(to: clips.appendingPathComponent("C0007M01.XML"), atomically: true, encoding: .utf8)
        let before = try TestSupport.snapshot(of: dir)
        let m = read(f)
        XCTAssertEqual(m.family, "Sony")
        XCTAssertEqual(m.cameraModel, "ILME-FX3")
        XCTAssertEqual(m.cameraSerial, "1234567")
        XCTAssertEqual(m.creationDate, "2026-10-28 10:11:12")
        XCTAssertEqual(m.extraColumns["sensorFPS"], "23.98")
        XCTAssertEqual(m.width, 320, "i dati tecnici restano quelli del file (ffprobe), non del sidecar")
        XCTAssertEqual(m.rawFields["sidecar:NonRealTimeMeta/Device@modelName"], "ILME-FX3")
        XCTAssertEqual(try TestSupport.snapshot(of: dir), before, "i file non vengono toccati")
    }

    func testGarbageSidecarIsIgnored() throws {
        try needTools()
        let f = dir.appendingPathComponent("C0008.MP4")
        try ffmpeg(["-f", "lavfi", "-i", "testsrc=size=64x48:rate=25", "-t", "1", "-c:v", "libx264", "-pix_fmt", "yuv420p", f.path])
        try Data("<<<non xml".utf8).write(to: dir.appendingPathComponent("C0008M01.XML"))
        let m = read(f)
        XCTAssertEqual(m.status, .read)
        XCTAssertNil(m.cameraMake)
    }

    // MARK: Tag usati dalle mappature

    func testEveryTagNameUsedByTheMappingExistsInExifTool() throws {
        guard tools.exiftool != nil else { throw XCTSkip("ExifTool non installato") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tools.exiftool!.executable)
        p.arguments = ["-listx"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let listing = String(decoding: data, as: UTF8.self)
        let names = ExifMapper.makeKeys + ExifMapper.modelKeys + ExifMapper.serialKeys + ExifMapper.firmwareKeys + ExifMapper.reelKeys
            + ExifMapper.lensKeys + ExifMapper.isoKeys + ExifMapper.focusKeys + ExifMapper.dateKeys + ExifMapper.otherKeys
        for n in names where n != "ImageSize" && !ExifMapper.dynamicKeys.contains(n) {   // (i nomi «dinamici» li crea ExifTool al volo dai dati del file)
            XCTAssertTrue(listing.contains("name='\(n)'"), "ExifTool non ha un tag «\(n)»")
        }
    }
}
