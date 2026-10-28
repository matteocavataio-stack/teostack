import XCTest
@testable import TeoStackCore

final class MetadataExportTests: XCTestCase {
    private func clip(_ id: Int64, _ name: String, hash: String?, meta: [String: String], audio: Bool = false) -> ClipRecord {
        ClipRecord(id: id, offloadID: 1, binID: 1, relativePath: "CLIP/" + name, name: name, size: 1234, sourceHash: hash, status: "ok",
                   destinationStatuses: ["ok", "ok"], isMedia: !audio, metadata: meta, offloadDate: Date(timeIntervalSince1970: 0),
                   binName: "A001", dayName: "DAY01", modifiedAt: nil, isAudio: audio)
    }

    private var clips: [ClipRecord] {
        [
            clip(1, "A001C001.mov", hash: "0123456789abcdef", meta: ["camera": "ALEXA 35", "iso": "800", "frameRate": "24", "durationSeconds": "10",
                                                                    "timecode": "01:00:00:00", "reel": "A001", "audioChannels": "2", "raw.MXF:Foo": "bar, \"baz\""]),
            clip(2, "B002.R3D", hash: nil, meta: ["camera": "RED, EPIC", "frameRate": "24"]),
            clip(3, "S01.wav", hash: "fedcba9876543210", meta: ["recorder": "Zaxcom"], audio: true),
        ]
    }

    func testJSONLinksEveryRecordToItsChecksumAndOmitsUnknownValues() throws {
        let data = try MetadataExporter.data(for: clips, format: .json, now: Date(timeIntervalSince1970: 0))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["clipCount"] as? Int, 3)
        let list = try XCTUnwrap(root["clips"] as? [[String: Any]])
        XCTAssertEqual(list[0]["xxh64"] as? String, "0123456789abcdef")
        XCTAssertNil(list[1]["xxh64"], "nessun hash inventato")
        XCTAssertEqual((list[0]["metadata"] as? [String: String])?["iso"], "800")
        XCTAssertNil((list[1]["metadata"] as? [String: String])?["iso"])
        XCTAssertEqual((list[0]["rawFields"] as? [String: String])?["MXF:Foo"], "bar, \"baz\"")
        XCTAssertNil(list[1]["rawFields"])
        XCTAssertEqual(list[0]["destinations"] as? [String], ["ok", "ok"])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("N/D"))
        let noRaw = try MetadataExporter.data(for: clips, format: .json, includeRaw: false)
        XCTAssertFalse(String(decoding: noRaw, as: UTF8.self).contains("rawFields"))
    }

    func testCSVQuotingEmptyCellsAndColumns() throws {
        let text = String(decoding: try MetadataExporter.data(for: clips, format: .csv), as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines[0].hasPrefix("Name,Path,Bin,Day,Size (bytes),XXH64,Status,"))
        XCTAssertTrue(lines[0].contains("Camera model"))
        XCTAssertTrue(lines[0].contains("raw: MXF:Foo"))
        XCTAssertTrue(lines[2].contains("\"RED, EPIC\""), "la virgola nel valore va tra virgolette")
        XCTAssertTrue(lines[1].contains("\"bar, \"\"baz\"\"\""))
        XCTAssertFalse(text.contains("N/D"))
        // la riga senza hash ha la cella vuota, non un valore finto
        XCTAssertTrue(lines[2].hasPrefix("B002.R3D,CLIP/B002.R3D,A001,DAY01,1234,,ok,"))
        XCTAssertFalse(String(decoding: try MetadataExporter.data(for: clips, format: .csv, includeRaw: false), as: UTF8.self).contains("raw:"))
    }

    func testALE() throws {
        let text = String(decoding: try MetadataExporter.data(for: clips, format: .ale), as: UTF8.self)
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(Array(lines.prefix(6)), ["Heading", "FIELD_DELIM\tTABS", "VIDEO_FORMAT\t1080", "AUDIO_FORMAT\t48khz", "FPS\t24", ""])
        XCTAssertEqual(lines[6], "Column")
        let header = lines[7].components(separatedBy: "\t")
        XCTAssertEqual(Array(header.prefix(7)), ["Name", "Tracks", "Start", "End", "Tape", "Source File", "XXH64"])
        XCTAssertTrue(header.contains("Camera Type") && header.contains("ISO"))
        XCTAssertFalse(header.contains("Lens"), "colonne senza nessun valore non si scrivono")
        XCTAssertEqual(lines[9], "Data")
        let row1 = lines[10].components(separatedBy: "\t")
        XCTAssertEqual(row1[0], "A001C001.mov")
        XCTAssertEqual(row1[1], "VA")
        XCTAssertEqual(row1[2], "01:00:00:00")
        XCTAssertEqual(row1[3], "01:00:10:00", "End = start + durata (24 fps intero)")
        XCTAssertEqual(row1[4], "A001")
        XCTAssertEqual(row1[6], "0123456789abcdef")
        let row2 = lines[11].components(separatedBy: "\t")
        XCTAssertEqual(row2[2], ""); XCTAssertEqual(row2[3], "", "senza timecode né durata niente Start/End")
        XCTAssertEqual(lines[12].components(separatedBy: "\t")[1], "A")
    }

    func testALEEndWithNonIntegerRateIsEmptyAndAddFramesWraps() {
        XCTAssertNil(MetadataExporter.addFrames("01:00:00:30", frames: 1, timebase: 24), "frame oltre il timebase: timecode non valido")
        XCTAssertEqual(MetadataExporter.addFrames("23:59:59:23", frames: 1, timebase: 24), "00:00:00:00")
        let c = clip(1, "x.mov", hash: nil, meta: ["frameRate": "23.976", "timecode": "01:00:00:00", "durationSeconds": "10"])
        let text = String(decoding: (try? MetadataExporter.data(for: [c], format: .ale)) ?? Data(), as: UTF8.self)
        XCTAssertTrue(text.contains("FPS\t23.976"))
        XCTAssertTrue(text.contains("x.mov\tV\t01:00:00:00\t\t"), "frame rate frazionario: End non calcolato")
    }

    func testEmptyList() throws {
        for f in MetadataExporter.Format.allCases { XCTAssertNoThrow(try MetadataExporter.data(for: [], format: f)) }
    }
}
