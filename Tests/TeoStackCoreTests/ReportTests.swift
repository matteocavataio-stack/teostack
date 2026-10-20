import XCTest
@testable import TeoStackCore

final class ARTExtraKeysTests: XCTestCase {
    func testNewKeysFromRealExport() throws {
        let m = ARTMetadataParser.parse(try Fixtures.json(Fixtures.artCmdExport))
        XCTAssertEqual(m["manufacturer"], "ARRI")
        XCTAssertEqual(m["cameraIndex"], "DW")
        XCTAssertEqual(m["lensSerial"], "132674")
        XCTAssertEqual(m["tilt"], "-14.2")
        XCTAssertEqual(m["roll"], "0.4")
        XCTAssertEqual(m["focusDistance"], "1.87 m")
        XCTAssertEqual(m["audioCodec"], "AES3")
        XCTAssertEqual(m["audioChannels"], "2")
        XCTAssertEqual(m["audioSampleRate"], "48000")
        XCTAssertEqual(m["audioBitDepth"], "24")
    }
}

final class ReportFormattingTests: XCTestCase {
    func testDurationSizeAndTimecode() {
        XCTAssertEqual(ReportFormatting.duration(35), "35 sec")
        XCTAssertEqual(ReportFormatting.duration(125), "2 min 5 sec")
        XCTAssertEqual(ReportFormatting.duration(3723), "1 h 2 min 3 sec")
        XCTAssertEqual(ReportFormatting.size(0), "0.00 KB")
        XCTAssertEqual(ReportFormatting.size(20_770_000_000), "20.77 GB")
        XCTAssertEqual(ReportFormatting.timecode("00:45:08:02"), "00:45:08.02")
        XCTAssertEqual(ReportFormatting.timecodeEnd(start: "00:45:08:02", frames: 328, fps: 25), "00:45:21.05")
        XCTAssertEqual(ReportFormatting.littleEndian(hex: "0102030405060708"), "0807060504030201")
    }

    func testFileNames() {
        let date = ReferenceScenario.date("20/10/2026 14:55")
        XCTAssertEqual(ReportKind.clips.fileName(scopeName: "A_9001_1C3S", date: date), "Clips_Report-A_9001_1C3S-2026-10-20-1455.pdf")
        XCTAssertEqual(ReportKind.contactPrint.fileName(scopeName: "A/B", date: date), "Contact_Print_Report-A-B-2026-10-20-1455.pdf")
        XCTAssertEqual(ReportKind.allCases.count, 5)
    }
}

final class ReportGenerationTests: XCTestCase {
    static let tinyJPEG = "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAAKABADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDFoooryj74/9k="

    private func bytes(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }
    private func pageCount(_ data: Data) -> Int { bytes(data).components(separatedBy: "/Type /Page ").count - 1 }

    /// Ogni offset della tabella xref deve puntare a «N 0 obj» e startxref a «xref».
    private func assertValidStructure(_ data: Data, file: StaticString = #filePath, line: UInt = #line) {
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("%PDF-"), file: file, line: line)
        XCTAssertTrue(text.hasSuffix("%%EOF\n"), file: file, line: line)
        guard let r = text.range(of: "startxref\n", options: .backwards) else { return XCTFail("startxref mancante", file: file, line: line) }
        let position = Int(text[r.upperBound...].split(separator: "\n")[0])!
        let bytes = [UInt8](data)
        XCTAssertEqual(String(decoding: bytes[position..<position + 4], as: UTF8.self), "xref", file: file, line: line)
        let tail = String(decoding: bytes[position...], as: UTF8.self).components(separatedBy: "\n")
        let entries = tail.filter { $0.hasSuffix(" 00000 n ") }
        XCTAssertFalse(entries.isEmpty, file: file, line: line)
        for (i, e) in entries.enumerated() {
            let offset = Int(e.prefix(10))!
            XCTAssertTrue(String(decoding: bytes[offset..<min(bytes.count, offset + 12)], as: UTF8.self).hasPrefix("\(i + 1) 0 obj"),
                          "oggetto \(i + 1) non allineato", file: file, line: line)
        }
    }

    func testAllFiveReportsAreValidPDFs() throws {
        let sc = try ReferenceScenario()
        for kind in ReportKind.allCases {
            let out = try ReportGenerator.generate(kind, store: sc.store, projectID: sc.project.id, nodeID: sc.bin.id,
                                                   options: ReportOptions(projectName: sc.projectName), thumbnails: nil)
            XCTAssertEqual(out.kind, kind)
            XCTAssertTrue(out.fileName.hasPrefix(kind.filePrefix + "-A_9001_1C3S-"), out.fileName)
            XCTAssertTrue(out.fileName.hasSuffix(".pdf"))
            assertValidStructure(out.data)
            let text = bytes(out.data)
            XCTAssertTrue(text.contains(kind.title), "\(kind) senza titolo")
            XCTAssertTrue(text.contains("A_9001_1C3S"), "\(kind) senza nome bin")
        }
    }

    func testPageGeometryMatchesReferenceFormats() throws {
        let sc = try ReferenceScenario()
        func mediaBox(_ kind: ReportKind) throws -> String {
            let text = bytes(try ReportGenerator.generate(kind, store: sc.store, projectID: sc.project.id, nodeID: sc.bin.id,
                                                          options: ReportOptions(projectName: "P"), thumbnails: nil).data)
            let r = try XCTUnwrap(text.range(of: "/MediaBox ["))
            return String(text[r.upperBound...].prefix(while: { $0 != "]" }))
        }
        XCTAssertEqual(try mediaBox(.volume), "0 0 595.28 841.89")
        XCTAssertEqual(try mediaBox(.thumbnail), "0 0 595.28 841.89")
        XCTAssertEqual(try mediaBox(.contactPrint), "0 0 841.89 595.28")
        XCTAssertTrue(try mediaBox(.clips).hasPrefix("0 0 1119"), "pagina larga quanto la somma delle 150 colonne")
    }

    func testShootingDayStatsAndBoxes() throws {
        let sc = try ReferenceScenario()
        let text = bytes(ShootingDayReport.render(try sc.context(.shootingDay)))
        for expected in ["Production Info", "Clips Overview", "Workflow", "Backups", "Bins", "Camera Sums", "Video Formats",
                         "35 sec", "20.77 GB", "4.02 KB", "ARRIRAW"] {
            XCTAssertTrue(text.contains(expected), expected)
        }
    }

    func testVolumeReportHasBothByteOrdersAndRealHashes() throws {
        let sc = try ReferenceScenario()
        let text = bytes(VolumeReport.render(try sc.context(.volume)))
        // come nel riferimento: «xxHash64» è l'hash a byte invertiti, «xxHash64BE» quello esadecimale dell'engine
        XCTAssertTrue(text.contains("xxHash64:" + ReportFormatting.littleEndian(hex: "266c70788d229207")))
        XCTAssertTrue(text.contains("xxHash64BE:266c70788d229207"))
        XCTAssertTrue(text.contains("A_9001_1C3S_AVID.ale"))
        XCTAssertTrue(text.contains("SSD_8TB_01"))
    }

    func testClipsReportRowsAndOnlyKnownValues() throws {
        let sc = try ReferenceScenario()
        let ctx = try sc.context(.clips)
        let text = bytes(ClipsReport.render(ctx))
        for expected in ["A_9001C001_250606_093620_a1C3S", "A_9001C002_250606_093639_a1C3S", "A_9001_1C3S_AVID.ale", "A_9001_1C3S_BIN.bin",
                         "00:45:08.02", "00:45:21.05", "5600 K", "1/50s", "180.0° @ 25fps".replacingOccurrences(of: "°", with: "\\260"),
                         "LogC4, AWG4", "XXH64BE:266c70788d229207", "verified", "No Label"] {
            XCTAssertTrue(text.contains(expected), expected)
        }
        // valori che l'app non conosce (ShotHub, Play Status…) non vengono inventati
        XCTAssertFalse(text.contains("Not synced with ShotHub yet"))
        XCTAssertFalse(text.contains("E4M-Z6J-3TG"))
        XCTAssertEqual(pageCount(ClipsReport.render(ctx)), 1)
    }

    func testFieldsLeaveUnknownBlank() throws {
        let sc = try ReferenceScenario()
        let ctx = try sc.context(.clips)
        let ale = try XCTUnwrap(ctx.items.first { $0.name == "A_9001_1C3S_AVID.ale" })
        if case .empty = ReportFields.cell("Duration", item: ale, ctx: ctx) {} else { XCTFail("durata di un ALE") }
        if case .empty = ReportFields.cell("Added By", item: ale, ctx: ctx) {} else { XCTFail("Added By") }
        if case .text(let t) = ReportFields.cell("Hash Values", item: ale, ctx: ctx) { XCTAssertEqual(t, "XXH64BE:f7f3950a4f9fa27a") } else { XCTFail() }
        if case .text(let t) = ReportFields.cell("File Type", item: ale, ctx: ctx) { XCTAssertEqual(t, "ale") } else { XCTFail() }
    }

    func testThumbnailReportHasOneCardPerFileAndContactPrintOnlyVideo() throws {
        let sc = try ReferenceScenario()
        let thumb = ThumbnailReport.render(try sc.context(.thumbnail))
        XCTAssertGreaterThan(pageCount(thumb), 1, "tutti i campi di 4 file non stanno in una pagina")
        let contact = bytes(ContactPrintReport.render(try sc.context(.contactPrint)))
        XCTAssertTrue(contact.contains("A_9001C001_250606_093620_a1C3S"))
        XCTAssertFalse(contact.contains("A_9001_1C3S_BIN.bin"), "il contact print mostra solo i clip video")
    }

    func testThumbnailJPEGIsEmbedded() throws {
        let sc = try ReferenceScenario()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("teo-report-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ThumbnailCache(directory: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let jpeg = try XCTUnwrap(Data(base64Encoded: ReportGenerationTests.tinyJPEG))
        for clip in try sc.store.clips(underNode: sc.bin.id, mediaOnly: true) {
            try jpeg.write(to: cache.imageURL(clipID: clip.id))
        }
        let data = try ContactPrintReport.render(sc.context(.contactPrint, thumbnails: cache))
        XCTAssertTrue(bytes(data).contains("/DCTDecode"))
        assertValidStructure(data)
    }

    func testCompactColumnsAreMultiplesOfPixelGrid() throws {
        let sc = try ReferenceScenario()
        let canvas = ReportCanvas(ctx: try sc.context(.contactPrint), setup: .contactPrint())
        let st = canvas.compactStyle()
        let widths = canvas.columnWidths(columns: [TableColumn(title: ""), TableColumn(title: "Size", alignment: .right)],
                                         rows: [[.text("Source Video Clips"), .text("20.77 GB")]], style: st, available: 0)
        XCTAssertEqual(widths[0], 95.2, accuracy: 0.001)
        for w in widths { XCTAssertEqual((w / 0.8).rounded(), w / 0.8, accuracy: 1e-6, "larghezza \(w) non multipla di 0.8") }
    }
}

final class ModifiedAtMigrationTests: XCTestCase {
    func testSourceModificationDateIsStored() throws {
        let sc = try ReferenceScenario()
        let clips = try sc.store.clips(underNode: sc.bin.id, mediaOnly: false)
        XCTAssertEqual(clips.count, 4)
        for c in clips { XCTAssertEqual(c.modifiedAt, ReferenceScenario.date("06/06/2025 11:36")) }
    }
}
