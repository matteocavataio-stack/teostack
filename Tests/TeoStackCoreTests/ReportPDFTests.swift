import XCTest
@testable import TeoStackCore

private func sampleDocument() -> ReportDocument {
    ReportDocument(
        title: "Report", template: "Classic",
        meta: [("Progetto", "Film <&> \"Uno\""), ("Operatore", "Mario Rossi"), ("Ambito", "Progetto completo"), ("Generato il", "20/10/2026 14:00")],
        blocks: [
            ReportBlock(section: .clips, title: "Clips", subtitle: "2 clip", content: .table(ReportTable(
                columns: [ReportColumn(id: "name", title: "Nome", width: 3), ReportColumn(id: "size", title: "Dimensione", width: 1, alignment: .right)],
                rows: [[ReportCell("A001;C001, \"x\".mov"), ReportCell("1.50 MB")],
                       [ReportCell("Città àèìòù.mov"), ReportCell("2.00 MB")]],
                footer: [ReportCell("Totale"), ReportCell("3.50 MB")]))),
            ReportBlock(section: .productionInfo, title: "Production Info", content: .keyValues([("Regista", "N/D"), ("Luogo", "Isarwehr")])),
            ReportBlock(section: .notes, title: "Note", content: .text("Prima riga\nSeconda <riga> & fine")),
        ])
}

final class ReportPDFTests: XCTestCase {
    /// Controlla la struttura PDF: header, offset della tabella xref, ogni oggetto all'offset dichiarato, %%EOF.
    private func assertValidPDFStructure(_ data: Data, file: StaticString = #filePath, line: UInt = #line) throws -> Int {
        let bytes = [UInt8](data)
        func text(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }
        XCTAssertEqual(text(0..<8), "%PDF-1.4", file: file, line: line)
        let tail = text(max(0, bytes.count - 200)..<bytes.count)
        XCTAssertTrue(tail.hasSuffix("%%EOF\n"), file: file, line: line)
        let startxref = try XCTUnwrap(tail.components(separatedBy: "startxref\n").last?.split(separator: "\n").first.flatMap { Int($0) }, file: file, line: line)
        XCTAssertEqual(text(startxref..<startxref + 4), "xref", file: file, line: line)
        let lines = text(startxref..<bytes.count).components(separatedBy: "\n")
        let count = try XCTUnwrap(Int(lines[1].split(separator: " ")[1]), file: file, line: line)
        for n in 1..<count {
            let entry = lines[2 + n]
            let offset = try XCTUnwrap(Int(entry.prefix(10)), file: file, line: line)
            XCTAssertTrue(text(offset..<offset + 12).hasPrefix("\(n) 0 obj"), "oggetto \(n) non è all'offset \(offset)", file: file, line: line)
        }
        return count - 1
    }

    private func bigDocument(rows: Int) -> ReportDocument {
        let cols = [ReportColumn(id: "name", title: "File", width: 3), ReportColumn(id: "path", title: "Posizione", width: 5),
                    ReportColumn(id: "size", title: "Dimensione", width: 1.3, alignment: .right), ReportColumn(id: "hash", title: "XXH64", width: 2.2)]
        let body = (0..<rows).map { i in
            [ReportCell("clip_\(i)_àèìòù.mov"), ReportCell("/Volumes/SSD_DIT/Film/DAY01_20261020/a001/CLIP/sub\(i)"),
             ReportCell("1.50 GB"), ReportCell("0123456789abcdef")]
        }
        return ReportDocument(title: "Report", template: "Classic", meta: [("Progetto", "Film"), ("Operatore", "Mario"), ("Ambito", "Progetto completo")],
                              blocks: [ReportBlock(section: .volume, title: "Volume «SSD_DIT»", subtitle: "/Volumes/SSD_DIT/a001",
                                                   content: .table(ReportTable(columns: cols, rows: body, footer: [ReportCell("Totale: \(rows)"), ReportCell(""), ReportCell(""), ReportCell("")])))])
    }

    func testPDFStructureIsValid() throws {
        let data = ReportPDF.render(sampleDocument())
        let objects = try assertValidPDFStructure(data)
        XCTAssertEqual(objects, 5 + 2)            // catalogo, pagine, 2 font, info + (pagina + contenuto)
    }

    func testPDFPaginatesLongTablesRepeatingHeaderAndNumbering() throws {
        let data = ReportPDF.render(bigDocument(rows: 400))
        let objects = try assertValidPDFStructure(data)
        let pages = (objects - 5) / 2
        XCTAssertGreaterThan(pages, 5)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("/Count \(pages)"))
        XCTAssertTrue(text.contains("Pagina \(pages) di \(pages)"))
        XCTAssertTrue(text.contains("Pagina 1 di \(pages)"))
    }

    func testPDFTextIsExtractableWithReferenceTool() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/pdftotext") else { throw XCTSkip("pdftotext non disponibile") }
        let dir = try TestSupport.makeTempDir("pdf")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("r.pdf")
        try ReportPDF.render(sampleDocument()).write(to: file)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pdftotext")
        p.arguments = ["-layout", file.path, "-"]
        let pipe = Pipe(); p.standardOutput = pipe
        try p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        for expected in ["Report", "Template Classic", "Progetto", "Mario Rossi", "Clips", "Dimensione", "1.50 MB", "Città àèìòù.mov",
                         "Production Info", "Regista", "N/D", "Isarwehr", "Note", "Prima riga", "Pagina 1 di 1", "A001;C001, \"x\".mov", "Totale"] {
            XCTAssertTrue(out.contains(expected), "manca «\(expected)» nel testo estratto:\n\(out)")
        }
    }

    func testPDFPageCountMatchesReferenceTool() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/pdfinfo") else { throw XCTSkip("pdfinfo non disponibile") }
        let dir = try TestSupport.makeTempDir("pdf")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("big.pdf")
        let data = ReportPDF.render(bigDocument(rows: 250))
        try data.write(to: file)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pdfinfo")
        p.arguments = [file.path]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        try p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, out)
        let objects = try assertValidPDFStructure(data)
        func field(_ name: String) -> String {
            out.components(separatedBy: "\n").first { $0.hasPrefix(name + ":") }?.dropFirst(name.count + 1).trimmingCharacters(in: .whitespaces) ?? ""
        }
        XCTAssertEqual(field("Pages"), String((objects - 5) / 2), out)
        XCTAssertEqual(field("Page size"), "842 x 595 pts (A4)", out)
        XCTAssertEqual(field("Title"), "Report – Film", out)
    }

    func testWrapBreaksLongWordsAndAddsEllipsis() {
        let lines = ReportPDF.wrap("/Volumes/SSD_DIT/Film/DAY01_20261020/a001/CLIP/qualcosa/di/molto/lungo/senza/spazi/xxxxxxxxxxxxxxxxxxxxxxxxxx",
                                   width: 120, size: 8, bold: false, maxLines: 10)
        XCTAssertGreaterThan(lines.count, 1)
        XCTAssertTrue(lines.allSatisfy { PDFWriter.width($0, size: 8, bold: false) <= 120.01 })
        XCTAssertEqual(lines.joined(), "/Volumes/SSD_DIT/Film/DAY01_20261020/a001/CLIP/qualcosa/di/molto/lungo/senza/spazi/xxxxxxxxxxxxxxxxxxxxxxxxxx")
        let cut = ReportPDF.wrap(String(repeating: "parola ", count: 60), width: 100, size: 8, bold: false, maxLines: 2)
        XCTAssertEqual(cut.count, 2)
        XCTAssertTrue(cut[1].hasSuffix("…"))
    }

    func testWinAnsiEncoding() {
        XCTAssertEqual(PDFWriter.winAnsi("àè"), [0xE0, 0xE8])
        XCTAssertEqual(PDFWriter.winAnsi("€…–"), [0x80, 0x85, 0x96])
        XCTAssertEqual(PDFWriter.winAnsi("日"), [0x3F], "carattere non rappresentabile → ?")
        XCTAssertGreaterThan(PDFWriter.width("WWWW", size: 10, bold: true), PDFWriter.width("iiii", size: 10, bold: true))
        XCTAssertEqual(PDFWriter.width("A", size: 1000, bold: false), 667, accuracy: 0.5)   // metrica ufficiale Helvetica
    }
}
