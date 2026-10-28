import XCTest
@testable import TeoStackCore

/// Metadata di clip VERE (JSON reali di ExifTool 13.59 e ffprobe, estratti sul Mac dell'utente; percorsi anonimizzati).
enum RealClip {
    static var dir: URL { Fixtures.directory.appendingPathComponent("real") }

    static func json(_ name: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let a = obj as? [[String: Any]] { return a.first }
        return obj as? [String: Any]
    }

    static func head(for name: String) -> Data {
        switch (name as NSString).pathExtension.lowercased() {
        case "r3d": return Data([0, 0, 0x10, 0] + Array("RED2".utf8) + [0, 0, 0, 0])
        case "mov": return Data([0, 0, 0, 0x14] + Array("ftypqt  ".utf8))
        case "mp4": return Data([0, 0, 0, 0x18] + Array("ftypmp42".utf8))
        case "mxf": return Data(FileProbe.mxfKey + [0, 0])
        case "dng": return Data([0x49, 0x49, 0x2A, 0x00, 8, 0, 0, 0])
        default: return Data()
        }
    }

    /// Un ClipFile le cui letture di ExifTool/ffprobe vengono dai JSON veri.
    static func file(_ name: String, art: Bool = false) -> ClipFile {
        let url = URL(fileURLWithPath: "/Volumes/CARD/" + name)
        let exif = json(name + ".exiftool.json")
        let ee = json(name + ".exiftool-ee.json")
        let probe = json(name + ".ffprobe.json")
        return ClipFile(url: url, tools: ReaderTools(),
                        probe: FileProbe(url: url, head: head(for: name), size: 1_000_000),
                        exifOverride: exif.map { e in { e } },
                        ffprobeOverride: probe.map { p in { p } },
                        embeddedOverride: ee.map { e in { e } })
    }

    static func read(_ name: String) -> ClipMetadata { ReaderRegistry.standard().read(file(name)) }
}

/// Aspettative sui clip VERI dell'utente. Ogni valore è nei JSON reali (o derivato con una regola documentata); ciò che il file non dichiara è nil.
final class RealClipTests: XCTestCase {
    func testREDVRaptor8K() {
        let m = RealClip.read("red_vraptor_8k.R3D")
        XCTAssertEqual(m.family, "RED")
        XCTAssertEqual(m.cameraMake, "RED")
        XCTAssertEqual(m.cameraModel, "V-RAPTOR [X] 8K VV", "il modello è «Brain»; «CameraType» è la lettera della camera")
        XCTAssertEqual(m.extraColumns["cameraIndex"], "A")
        XCTAssertEqual(m.reel, "A008")
        XCTAssertEqual(m.extraColumns["take"], "009")
        XCTAssertEqual(m.cameraSerial, "VRPBX000028")
        XCTAssertEqual(m.firmware, "1.8.1beta")
        XCTAssertEqual(m.width, 8192); XCTAssertEqual(m.height, 4320)
        XCTAssertEqual(m.fps, 23.976)
        XCTAssertEqual(m.iso, "800")
        XCTAssertEqual(m.whiteBalance, "2900 K")
        XCTAssertEqual(m.codec, "REDCODE RAW (MQ)")
        XCTAssertEqual(m.creationDate, "2024-10-25 12:23:57")
        XCTAssertNil(m.lensModel, "«unknown» = lente non comunicata")
        XCTAssertNil(m.clipName)
        XCTAssertEqual(m.timecodeStart, "12:23:34:16", "il secondo dei due timecode del file, confermato dall'utente su Silverstack")
        XCTAssertNil(m.duration)
        XCTAssertEqual(m.rawFields["Red:Red_0x10ad"], "01:05:29:06")
        XCTAssertEqual(m.rawFields["Red:Red_0x10ae"], "12:23:34:16")
        XCTAssertEqual(m.rawFields["Red:StorageModel"], "RD4.15")
        XCTAssertNil(m.rawFields["System:FileName"])
    }

    func testSonyVenice2MXF() {
        let m = RealClip.read("sony_venice2_xocn.mxf")
        XCTAssertEqual(m.family, "Sony", "riconosciuto dal produttore del registratore (AXS), non dichiarato come camera")
        XCTAssertNil(m.cameraMake, "ApplicationSupplierName è il software: mai la camera")
        XCTAssertNil(m.cameraModel, "il modello della VENICE non sta nell'MXF (sta nel sidecar XML): non si inventa")
        XCTAssertEqual(m.container, "MXF")
        XCTAssertEqual(m.width, 8640); XCTAssertEqual(m.height, 5760)
        XCTAssertEqual(m.fps, 24)
        XCTAssertEqual(m.duration, 42.75)
        XCTAssertEqual(m.timecodeStart, "14:14:01:01")
        XCTAssertEqual(m.audioChannels, 4)
        XCTAssertEqual(m.audioSampleRate, 48000)
        XCTAssertNil(m.codec, "il flusso X-OCN non ha un nome di codec nel file")
        XCTAssertEqual(m.creationDate, "2022-06-09 21:14:00")
        XCTAssertEqual(m.rawFields["Track2:SampledWidth"], "8664")
        XCTAssertEqual(m.rawFields["ffprobe:format.tags.company_name"], "Sony")
    }

    func testDJIInspire3ProResRAW() {
        let m = RealClip.read("dji_inspire3_proresraw.mov")
        XCTAssertEqual(m.family, "DJI")
        XCTAssertEqual(m.cameraMake, "DJI"); XCTAssertEqual(m.cameraModel, "Inspire 3")
        XCTAssertEqual(m.codec, "Apple ProRes RAW")
        XCTAssertEqual(m.width, 8192); XCTAssertEqual(m.height, 3424)
        XCTAssertEqual(m.fps, 60); XCTAssertEqual(m.frameCount, 1944); XCTAssertEqual(m.duration, 32.4)
        XCTAssertEqual(m.timecodeStart, "21:38:29:11")
        XCTAssertEqual(m.iso, "500"); XCTAssertEqual(m.whiteBalance, "5400 K"); XCTAssertEqual(m.shutterAngle, "194.4°"); XCTAssertEqual(m.aperture, "2.8")
        XCTAssertEqual(m.lensModel, "DJI_DL_35mm_F2.8_LS_ASPH"); XCTAssertEqual(m.extraColumns["lensSerial"], "07JY124G031P")
        XCTAssertEqual(m.cameraSerial, "564BKAU10205JG"); XCTAssertEqual(m.firmware, "10.00.14.03")
        XCTAssertEqual(m.reel, "A005_4U1Q"); XCTAssertEqual(m.clipName, "A005C0032_230327_4U1Q.MOV"); XCTAssertEqual(m.extraColumns["cameraIndex"], "A")
        XCTAssertEqual(m.gamma, "Linear", "quello che dichiara il file")
        XCTAssertEqual(m.extraColumns["lookInfo"], "D-Log", "la modalità di registrazione va in «Look Info»")
        XCTAssertEqual(m.rawFields["Track2:Dvtm_fc4280_2-2-11-1"], "D-Log")
        XCTAssertNil(m.focalLength, "il numero non è dichiarato (solo nel nome della lente)")
        XCTAssertNil(m.focusDistance)
        XCTAssertEqual(m.container, "QuickTime")
    }

    func testDJICinemaDNGFrame() {
        let m = RealClip.read("dji_fc4280_cinemadng.DNG")
        XCTAssertEqual(m.family, "DJI")
        XCTAssertEqual(m.codec, "CinemaDNG")
        XCTAssertEqual(m.cameraModel, "FC4280"); XCTAssertEqual(m.cameraSerial, "564BK8J10205ZJ"); XCTAssertEqual(m.firmware, "10.00.08.40")
        XCTAssertEqual(m.iso, "4000"); XCTAssertEqual(m.shutter, "1/50"); XCTAssertEqual(m.aperture, "11"); XCTAssertEqual(m.focalLength, "50 mm")
        XCTAssertEqual(m.whiteBalance, "5600 K")
        XCTAssertEqual(m.timecodeStart, "08:14:48:18", "TimeCodes «18.48.14.08» = BCD frame/sec/min/ore")
        XCTAssertEqual(m.fps, 25); XCTAssertEqual(m.extraColumns["sensorFPS"], "25")
        XCTAssertEqual(m.cameraTilt, "0.1"); XCTAssertEqual(m.cameraRoll, "0")
        XCTAssertEqual(m.reel, "Y507C0006_230216_0129_000504")
        XCTAssertEqual(m.width, 8192); XCTAssertEqual(m.height, 4320)
        XCTAssertNil(m.duration, "un fotogramma non ha durata")
        XCTAssertNil(m.lensModel)
        XCTAssertEqual(m.rawFields["XMP-drone-dji:GPSLatitude"], "+46.549256182")
        XCTAssertEqual(m.rawFields["XMP-drone-dji:GimbalYawDegree"], "+149.70")
    }

    func testResolveProRes422ProxyKeepsReelNameAndDeclaredColour() {
        let m = RealClip.read("resolve_proxy_prores.mov")
        XCTAssertEqual(m.family, "Generic")
        XCTAssertEqual(m.codec, "ProRes Proxy")
        XCTAssertEqual(m.reel, "A_0003C001_261027_142514_h1CK8")
        XCTAssertEqual(m.timecodeStart, "13:00:54:01")
        XCTAssertEqual(m.width, 4608); XCTAssertEqual(m.height, 3164); XCTAssertEqual(m.fps, 25)
        XCTAssertEqual(m.colorSpace, "Rec.709"); XCTAssertEqual(m.gamma, "BT.709")
        XCTAssertNil(m.cameraMake, "«Blackmagic Design DaVinci Resolve» è il programma che ha scritto il file, non la camera")
        XCTAssertNil(m.cameraModel)
        XCTAssertEqual(m.rawFields["ffprobe:format.tags.encoder"], "Blackmagic Design DaVinci Resolve Studio")
    }

    func testPlainH264UHDStaysGeneric() {
        let m = RealClip.read("generic_h264_uhd.mp4")
        XCTAssertEqual(m.family, "Generic")
        XCTAssertEqual(m.codec, "H.264 High")
        XCTAssertEqual(m.width, 3840); XCTAssertEqual(m.fps, 30); XCTAssertEqual(m.frameCount, 1717)
        XCTAssertNil(m.cameraMake); XCTAssertNil(m.iso); XCTAssertNil(m.reel)
        XCTAssertNil(m.audioChannels)
    }

    func testEveryRealClipAlsoKeepsItsExtraTagsAndDatabaseRoundTrips() {
        for n in ["red_vraptor_8k.R3D", "sony_venice2_xocn.mxf", "dji_inspire3_proresraw.mov", "dji_fc4280_cinemadng.DNG", "resolve_proxy_prores.mov", "generic_h264_uhd.mp4"] {
            let m = RealClip.read(n)
            XCTAssertGreaterThan(m.rawFields.count, 50, n)
            let back = ClipMetadata(columns: m.columns)
            XCTAssertEqual(back.columns, m.columns, n)
            XCTAssertFalse(m.columns.values.contains("N/D"), n)
        }
    }

    func testHelpers() {
        XCTAssertEqual(ExifMapper.dngTimecode("18.48.14.08.00.00.00.00"), "08:14:48:18")
        XCTAssertEqual(ExifMapper.dngTimecode("59.59.59.23.00.00.00.00"), "23:59:59;19", "bit 0x40 = drop-frame")
        XCTAssertNil(ExifMapper.dngTimecode("1a.00.00.00"))
        XCTAssertNil(ExifMapper.dngTimecode("not a timecode"))
        XCTAssertEqual(ExifMapper.leadingNumber("194.40deg"), 194.4)
        XCTAssertEqual(ExifMapper.leadingNumber("5400K"), 5400)
        XCTAssertEqual(ExifMapper.leadingNumber("F2.8"), 2.8)
        XCTAssertNil(ExifMapper.leadingNumber("deg"))
        for placeholder in ["unknown", "Unknown", "", "N/A", "none", "0"] { XCTAssertNil(ExifMapper.real(placeholder), placeholder) }
        XCTAssertEqual(ExifMapper.real(" RF35mm "), "RF35mm")
    }
}
