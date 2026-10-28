import XCTest
@testable import TeoStackCore

final class SidecarImportTests: XCTestCase {
    func testALE() {
        let ale = "Heading\r\nFIELD_DELIM\tTABS\r\nVIDEO_FORMAT\t1080\r\nFPS\t24\r\n\r\nColumn\r\nName\tTape\tScene\tTake\tStart\tNotes\r\n\r\nData\r\nA001C001\tA001\t12A\t3\t01:00:00:00\tbuona, circle\r\nA001C002\tA001\t12A\t4\t\t\r\n"
        let r = SidecarParser.parseALE(ale)
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0].fields["Scene"], "12A")
        XCTAssertEqual(r[0].fields["Notes"], "buona, circle")
        XCTAssertNil(r[1].fields["Start"], "cella vuota = campo assente")
    }

    func testCSVWithQuotesDelimitersAndBOM() {
        let comma = "Clip,Scene,Take,Notes\nA001C001.mov,12,3,\"ok, \"\"good\"\"\"\nA001C002.mov,12,4,\n"
        let r = SidecarParser.parseCSV(comma)
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0].fields["Notes"], "ok, \"good\"")
        let semi = "Clip;Scene;Take\nB001;5;1\n"
        XCTAssertEqual(SidecarParser.parseCSV(semi).first?.fields["Scene"], "5")
        let tab = "File\tRoll\nB002.mxf\tR7\n"
        XCTAssertEqual(SidecarParser.parseCSV(tab).first?.fields["Roll"], "R7")
        XCTAssertEqual(SidecarParser.decode(Data([0xEF, 0xBB, 0xBF]) + Data("Clip,Scene\n".utf8)), "Clip,Scene\n")
        XCTAssertTrue(SidecarParser.parseCSV("").isEmpty)
    }

    func testXMLWithRepeatedRecords() {
        let xml = """
        <?xml version="1.0"?>
        <Log><Project>Film</Project>
          <Clip name="A001C001" scene="12A" take="3"><Notes>circle</Notes><Timecode>01:00:00:00</Timecode></Clip>
          <Clip name="A001C002" scene="12A" take="4"/>
        </Log>
        """
        let r = SidecarParser.parseXML(Data(xml.utf8))
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0].fields["name"], "A001C001")
        XCTAssertEqual(r[0].fields["Notes"], "circle")
        XCTAssertEqual(r[1].fields["take"], "4")
        XCTAssertTrue(SidecarParser.parseXML(Data("<a><b>".utf8)).isEmpty)
    }

    func testFieldAliases() {
        XCTAssertEqual(SidecarFieldMap.canonical("Tape"), "reel")
        XCTAssertEqual(SidecarFieldMap.canonical("Clip Name"), "name")
        XCTAssertEqual(SidecarFieldMap.canonical("Scene No."), "scene")
        XCTAssertEqual(SidecarFieldMap.canonical("TC In"), "start")
        XCTAssertNil(SidecarFieldMap.canonical("Weather"))
    }

    // MARK: Abbinamento e scrittura

    private func store(with clips: [(name: String, meta: [String: String])]) throws -> (ProjectStore, [ClipRecord]) {
        let store = try ProjectStore(path: nil)
        let p = try store.createProject(name: "Film")
        let bin = try store.createBin(parentID: try store.tree(projectID: p.id).id, name: "Importati")
        let files = clips.enumerated().map { SourceFile(relativePath: $1.name, size: 10, modificationDate: Date(), creationDate: nil) }
        _ = try store.importFiles(binID: bin.id, rootPath: "/x", files: files)
        for c in try store.clips(underNode: bin.id, mediaOnly: false) {
            if let meta = clips.first(where: { $0.name == c.name })?.meta, !meta.isEmpty { try store.updateMetadata(clipID: c.id, merging: meta) }
        }
        return (store, try store.clips(underNode: bin.id, mediaOnly: false))
    }

    func testMatchByNameWritesOnlyEmptyFieldsUnlessOverwrite() throws {
        let (s, clips) = try store(with: [("A001C001.mov", ["scene": "99"]), ("A001C002.mov", [:]), ("Z.mov", [:])])
        let records = SidecarParser.parseCSV("Clip,Scene,Take,Tape,Weather\nA001C001,12A,3,A001,sole\nA001C002.MOV,12A,4,A001,\nNONE,1,1,X,\n")
        let report = try SidecarImporter.apply(records, to: clips, store: s)
        XCTAssertEqual(report.matched, 2)
        XCTAssertEqual(report.unmatched, ["NONE"])
        XCTAssertEqual(report.fieldsKept, 1, "scene 99 già presente: non toccata senza il consenso esplicito")
        let after = try s.clips(underNode: clips[0].binID, mediaOnly: false)
        let c1 = try XCTUnwrap(after.first { $0.name == "A001C001.mov" })
        XCTAssertEqual(c1.metadata["scene"], "99")
        XCTAssertEqual(c1.metadata["take"], "3")
        XCTAssertEqual(c1.metadata["reel"], "A001")
        XCTAssertEqual(c1.metadata["raw.sidecar:Weather"], "sole")
        XCTAssertEqual(after.first { $0.name == "A001C002.mov" }?.metadata["take"], "4")

        let again = try SidecarImporter.apply(records, to: try s.clips(underNode: clips[0].binID, mediaOnly: false), store: s, overwrite: true)
        XCTAssertEqual(again.fieldsKept, 0)
        XCTAssertEqual(try s.clips(underNode: clips[0].binID, mediaOnly: false).first { $0.name == "A001C001.mov" }?.metadata["scene"], "12A")
    }

    func testAmbiguousNamesAreSkipped() throws {
        let (s, clips) = try store(with: [("A001C001.mov", [:]), ("A001C001.mxf", [:])])
        let report = try SidecarImporter.apply(SidecarParser.parseCSV("Clip,Scene\nA001C001,5\n"), to: clips, store: s)
        XCTAssertEqual(report.ambiguous, ["A001C001"])
        XCTAssertEqual(report.matched, 0)
        XCTAssertTrue(try s.clips(underNode: clips[0].binID, mediaOnly: false).allSatisfy { $0.metadata["scene"] == nil })
    }

    func testMatchByTimecodeAndDate() throws {
        let (s, clips) = try store(with: [("x1.mov", ["timecode": "01:00:00:00", "createDate": "2026-10-28 10:00:00"]),
                                          ("x2.mov", ["timecode": "01:00:00:00", "createDate": "2026-10-29 10:00:00"])])
        let report = try SidecarImporter.apply(SidecarParser.parseCSV("TC In,Date,Scene\n01:00:00:00,28/10/2026,7\n01:00:00:00,,8\n"), to: clips, store: s)
        XCTAssertEqual(report.matched, 1)
        XCTAssertEqual(report.unmatched.count, 1, "senza data il solo timecode non basta")
        XCTAssertEqual(try s.clips(underNode: clips[0].binID, mediaOnly: false).first { $0.name == "x1.mov" }?.metadata["scene"], "7")
        XCTAssertNil(try s.clips(underNode: clips[0].binID, mediaOnly: false).first { $0.name == "x2.mov" }?.metadata["scene"])
    }

    func testFileParsingErrors() throws {
        let dir = try TestSupport.makeTempDir("sidecar")
        defer { try? FileManager.default.removeItem(at: dir) }
        let empty = dir.appendingPathComponent("e.csv")
        try Data().write(to: empty)
        XCTAssertThrowsError(try SidecarParser.parse(url: empty))
        XCTAssertThrowsError(try SidecarParser.parse(url: dir.appendingPathComponent("missing.ale")))
        XCTAssertThrowsError(try SidecarParser.parse(url: dir.appendingPathComponent("x.pdf")))
        let ale = dir.appendingPathComponent("l.ale")
        try "Column\nName\tScene\n\nData\nA\t1\n".write(to: ale, atomically: true, encoding: .utf8)
        XCTAssertEqual(try SidecarParser.parse(url: ale).count, 1)
    }
}
