import XCTest
#if canImport(FoundationXML)
import FoundationXML
#endif
@testable import TeoStackCore

/// Progetto di prova con un offload su 2 destinazioni e metadata ARRI reali (fixture) sui 4 clip video.
class ReportTestCase: XCTestCase {
    var store: ProjectStore!
    var card: FakeCard!
    var base: URL!
    var project: Project!
    var day: TreeNode!
    var bin: TreeNode!
    var destinations: [URL] = []

    override func setUpWithError() throws {
        store = try ProjectStore(path: nil)
        card = try FakeCard.create()
        base = try TestSupport.makeTempDir("reports")
        project = try store.createProject(name: "Film")
        day = try store.createDay(projectID: project.id, name: "DAY01_20261020")
        bin = try store.createBin(dayID: day.id, name: "a001")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: card.root.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: base)
    }

    @discardableResult
    func offload(to bin: TreeNode, destinationCount: Int = 2, tag: String = "") throws -> OffloadResult {
        destinations = (1...destinationCount).map { base.appendingPathComponent("Volumes/SSD\($0)\(tag)/\(bin.name)", isDirectory: true) }
        for d in destinations { try FileManager.default.createDirectory(at: d.deletingLastPathComponent(), withIntermediateDirectories: true) }
        let job = OffloadJob(sourceURL: card.root, destinationRoots: destinations)
        try store.beginOffload(jobID: job.id, binID: bin.id, sourcePath: card.root.path, destinations: destinations.map(\.path))
        let result = OffloadEngine(job: job, scan: try SourceScanner.scan(root: card.root)).run()
        try store.finishOffload(result)
        return result
    }

    func addARRIMetadata(to bin: TreeNode) throws {
        var values = ARRIMetadataParser.parse(try Fixtures.tags(Fixtures.arriAlexa35))
        values.merge(ARTMetadataParser.parse(try Fixtures.json(Fixtures.artCmdExport))) { _, new in new }
        for clip in try store.clips(underNode: bin.id) { try store.updateMetadata(clipID: clip.id, merging: values) }
    }

    func build(_ sections: Set<ReportSection>, node: Int64? = nil, columns: [String] = ClipColumns.defaultVisibleIDs,
               operatorName: String = "Mario DIT", notes: String = "") throws -> ReportDocument {
        try ReportBuilder.build(store: store, projectID: project.id, nodeID: node ?? bin.id,
                                options: ReportOptions(projectName: "Film", operatorName: operatorName, notes: notes,
                                                       sections: sections, clipColumnIDs: columns,
                                                       generatedAt: Date(timeIntervalSince1970: 1_800_000_000)))
    }

    func table(_ doc: ReportDocument, _ section: ReportSection) throws -> ReportTable {
        let block = try XCTUnwrap(doc.blocks.first { $0.section == section })
        guard case .table(let t) = block.content else { throw XCTSkip("la sezione non è una tabella") }
        return t
    }

    func keyValues(_ doc: ReportDocument, _ section: ReportSection) throws -> [String: String] {
        let block = try XCTUnwrap(doc.blocks.first { $0.section == section })
        guard case .keyValues(let items) = block.content else { throw XCTSkip("la sezione non è chiave/valore") }
        return Dictionary(items, uniquingKeysWith: { a, _ in a })
    }
}

final class ReportBuilderTests: ReportTestCase {
    func testHeaderHasProjectOperatorScopeAndDate() throws {
        try offload(to: bin)
        let doc = try build([.shootingDay])
        XCTAssertEqual(doc.template, "Classic")
        XCTAssertEqual(doc.meta.map(\.0), ["Progetto", "Operatore", "Ambito", "Generato il"])
        XCTAssertEqual(doc.meta[0].1, "Film")
        XCTAssertEqual(doc.meta[1].1, "Mario DIT")
        XCTAssertEqual(doc.meta[2].1, "Bin a001 (giorno DAY01_20261020)")
        XCTAssertEqual(try build([.shootingDay], operatorName: "  ").meta[1].1, "N/D")
        XCTAssertEqual(try build([.shootingDay], node: day.id).meta[2].1, "Giorno DAY01_20261020")
        XCTAssertEqual(try build([.shootingDay], node: try store.tree(projectID: project.id).id).meta[2].1, "Progetto completo")
    }

    func testOnlySelectedSectionsInTheStandardOrder() throws {
        try offload(to: bin)
        let doc = try build([.videoFormats, .clips, .shootingDay])
        XCTAssertEqual(doc.blocks.map(\.section), [.shootingDay, .clips, .videoFormats])
    }

    func testShootingDayRow() throws {
        try offload(to: bin)
        try addARRIMetadata(to: bin)
        let t = try table(try build([.shootingDay], node: day.id), .shootingDay)
        XCTAssertEqual(t.rows.count, 1)
        let row = t.rows[0].map(\.display)
        XCTAssertEqual(row[0], "DAY01_20261020")
        XCTAssertEqual(row[1], "4")                                          // clip video
        XCTAssertEqual(row[2], String(card.files.count))                     // tutti i file, anche XML ecc.
        XCTAssertEqual(t.rows[0][3].display, Format.bytes(Int64(card.files.reduce(0) { $0 + $1.size })))
        XCTAssertEqual(row[4], "00:00:28")                                   // 4 × 6,875 s = 27,5 s
        XCTAssertEqual(row[5], "2 copie verificate (tutti OK)")
        XCTAssertEqual(row[6], "ARRIRAW uncompressed 2048x1152 24 fps")
        XCTAssertNil(t.footer, "il totale compare solo con più giorni")
    }

    func testShootingDayWithTwoDaysHasTotalsAndEmptyDayShowsZeros() throws {
        try offload(to: bin)
        let empty = try store.createDay(projectID: project.id, name: "DAY02_20261021")
        let t = try table(try build([.shootingDay], node: try store.tree(projectID: project.id).id), .shootingDay)
        XCTAssertEqual(t.rows.map { $0[0].display }, ["DAY01_20261020", "DAY02_20261021"])
        XCTAssertEqual(t.rows[1].map(\.display).prefix(3), ["DAY02_20261021", "0", "0"])
        XCTAssertEqual(t.rows[1][5].display, "Nessun offload")
        XCTAssertEqual(t.footer?[0].display, "Totale")
        XCTAssertEqual(t.footer?[2].display, String(card.files.count))
        XCTAssertNotNil(empty)
    }

    func testDurationAndFormatsAreNDWithoutMetadata() throws {
        try offload(to: bin)
        let row = try table(try build([.shootingDay]), .shootingDay).rows[0].map(\.display)
        XCTAssertEqual(row[4], "N/D")
        XCTAssertEqual(row[6], "N/D")
    }

    func testPartialDurationIsFlagged() throws {
        try offload(to: bin)
        let clips = try store.clips(underNode: bin.id)
        try store.updateMetadata(clipID: clips[0].id, merging: ["durationSeconds": "10"])
        try store.updateMetadata(clipID: clips[1].id, merging: ["durationSeconds": "5"])
        let cell = try table(try build([.shootingDay]), .shootingDay).rows[0][4]
        XCTAssertEqual(cell.display, "00:00:15 (parziale: 2/4 clip)")
    }

    func testBackupTextReportsProblems() {
        func clip(_ statuses: [String]) -> ClipRecord {
            ClipRecord(id: 1, offloadID: 1, binID: 1, relativePath: "a.mov", name: "a.mov", size: 1, sourceHash: "x", status: "ok",
                       destinationStatuses: statuses, isMedia: true, metadata: [:], offloadDate: Date(), binName: "b", dayName: "d")
        }
        XCTAssertEqual(ReportBuilder.backupText([clip(["ok"])]), "1 copia verificata (tutti OK)")
        XCTAssertEqual(ReportBuilder.backupText([clip(["ok", "ok"]), clip(["ok", "ok"])]), "2 copie verificate (tutti OK)")
        XCTAssertEqual(ReportBuilder.backupText([clip(["ok", "ok"]), clip(["ok", "mismatch"])]), "1 di 2 copie complete: 1 MISMATCH")
        XCTAssertEqual(ReportBuilder.backupText([clip(["error", "ok"])]), "1 di 2 copie complete: 1 ERRORI")
        XCTAssertEqual(ReportBuilder.backupText([]), "Nessun offload")
    }

    func testClipsTableUsesSelectedColumnsAndShowsND() throws {
        try offload(to: bin)
        try addARRIMetadata(to: bin)
        let t = try table(try build([.clips], columns: ["name", "iso", "lens", "ndFilter", "sensorFPS", "whiteBalance", "lookInfo", "size", "hash"]), .clips)
        XCTAssertEqual(t.columns.map(\.id), ["name", "iso", "lens", "ndFilter", "sensorFPS", "whiteBalance", "lookInfo", "size", "hash"])
        XCTAssertEqual(t.rows.count, 4, "solo i clip video")
        XCTAssertEqual(t.rows[0][1].display, "800")
        XCTAssertEqual(t.rows[0][2].display, "ARRI SZ65-300 T2.8")
        XCTAssertEqual(t.rows[0][3].display, "ND 1.2")
        XCTAssertEqual(t.rows[0][5].display, "5600 K")
        XCTAssertEqual(t.rows[0][7].display, "3.00 MB")
        XCTAssertEqual(t.rows[0][8].display.count, 16)
        // metadata non letti → N/D
        let t2 = try table(try build([.clips], columns: ["name", "codec"]), .clips)
        let bare = try ReportBuilder.build(store: store, projectID: project.id, nodeID: bin.id,
                                           options: ReportOptions(projectName: "Film", sections: [.clips], clipColumnIDs: ["name", "codec"]))
        XCTAssertNotNil(bare)
        XCTAssertEqual(t2.rows[0][1].display, "ARRIRAW uncompressed")
        XCTAssertEqual(try table(bare, .clips).rows.count, 4)
    }

    func testPreviewColumnIsNotPrintedInTheReport() throws {
        try offload(to: bin)
        let t = try table(try build([.clips], columns: ["preview", "name"]), .clips)
        XCTAssertEqual(t.columns.map(\.id), ["name"])
        let clip = ClipRecord(id: 1, offloadID: 1, binID: 1, relativePath: "a.mov", name: "a.mov", size: 1, sourceHash: nil, status: "ok",
                              destinationStatuses: ["ok"], isMedia: true, metadata: [:], offloadDate: Date(), binName: "b", dayName: "d")
        XCTAssertEqual(ClipColumns.value(try XCTUnwrap(ClipColumns.column(id: "preview")), of: clip), "")
        XCTAssertEqual(ClipColumns.defaultVisibleIDs.first, "preview")
    }

    func testVolumeHasOneBlockPerDestinationWithHashAndLocation() throws {
        try offload(to: bin)
        let doc = try build([.volume])
        let blocks = doc.blocks.filter { $0.section == .volume }
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].title, "Volume «Disco interno»", "fuori da /Volumes il volume non ha un nome")
        XCTAssertEqual(blocks[0].subtitle, destinations[0].path)
        guard case .table(let t) = blocks[0].content else { return XCTFail() }
        XCTAssertEqual(t.rows.count, card.files.count, "nel Volume ci sono TUTTI i file, anche XML e file vuoti")
        let mxf = try XCTUnwrap(t.rows.first { $0[0].display == "C0001.MXF" })
        let expected = try TestSupport.xxhsumHash(of: card.root.appendingPathComponent("CLIP/C0001.MXF"))
        XCTAssertEqual(mxf[3].display, expected)
        XCTAssertEqual(mxf[1].display, destinations[0].appendingPathComponent("CLIP").path)
        XCTAssertEqual(mxf[4].display, "OK")
        XCTAssertEqual(t.footer?[0].display, "Totale: \(card.files.count) file")
        XCTAssertEqual(t.footer?[2].display, Format.bytes(Int64(card.files.reduce(0) { $0 + $1.size })))
    }

    func testVolumeNameFromVolumesPath() {
        XCTAssertEqual(ReportBuilder.volumeName("/Volumes/SSD_DIT/Film/a001"), "SSD_DIT")
        XCTAssertEqual(ReportBuilder.volumeName("/Users/me/Desktop/a001"), "Disco interno")
    }

    func testVolumeShowsMismatchAndMissingOffloads() throws {
        let empty = try build([.volume])
        guard case .text(let message) = empty.blocks[0].content else { return XCTFail() }
        XCTAssertTrue(message.contains("Nessun offload"))
    }

    func testProductionInfoFromMetadata() throws {
        try offload(to: bin)
        try addARRIMetadata(to: bin)
        let kv = try keyValues(try build([.productionInfo]), .productionInfo)
        XCTAssertEqual(kv["Progetto"], "Film")
        XCTAssertEqual(kv["Operatore"], "Mario DIT")
        XCTAssertEqual(kv["Produzione"], "Sample Footage")
        XCTAssertEqual(kv["Casa di produzione"], "ARRI")
        XCTAssertEqual(kv["Regista"], "DWS Dir")
        XCTAssertEqual(kv["Direttore della fotografia"], "DWS Cin")
        XCTAssertEqual(kv["Luogo"], "Isarwehr")
        XCTAssertEqual(kv["Camera"], "ARRI ALEXA 35")
        XCTAssertEqual(kv["Date di ripresa"], "2025-10-20")
    }

    func testProductionInfoIsNDWithoutMetadata() throws {
        try offload(to: bin)
        let kv = try keyValues(try build([.productionInfo]), .productionInfo)
        XCTAssertEqual(kv["Regista"], "N/D")
        XCTAssertEqual(kv["Date di ripresa"], "N/D")
    }

    func testClipsOverview() throws {
        try offload(to: bin)
        try addARRIMetadata(to: bin)
        let kv = try keyValues(try build([.clipsOverview], node: try store.tree(projectID: project.id).id), .clipsOverview)
        XCTAssertEqual(kv["Clip"], "4")
        XCTAssertEqual(kv["File totali"], String(card.files.count))
        XCTAssertEqual(kv["File OK"], String(card.files.count))
        XCTAssertEqual(kv["File MISMATCH"], "0")
        XCTAssertEqual(kv["File ERRORE"], "0")
        XCTAssertEqual(kv["Giorni"], "1")
        XCTAssertEqual(kv["Bin"], "1")
        XCTAssertEqual(kv["Offload eseguiti"], "1")
        XCTAssertEqual(kv["Durata totale"], "00:00:28")
        XCTAssertNotEqual(kv["Primo offload"], "N/D")
    }

    func testCameraSummaryAndVideoFormats() throws {
        try offload(to: bin)
        try addARRIMetadata(to: bin)
        let cam = try table(try build([.cameraSummary]), .cameraSummary)
        XCTAssertEqual(cam.rows.count, 1)
        XCTAssertEqual(cam.rows[0].map(\.display), ["ARRI ALEXA 35", "70253", "5.01.00", "4", "00:00:28", Format.bytes(Int64(3_000_000 + 1_234_567 + 20_000_001 + 5_000_000)), "ARRI SZ65-300 T2.8"])
        let fmt = try table(try build([.videoFormats]), .videoFormats)
        XCTAssertEqual(fmt.rows.map { $0.map(\.display).prefix(4) }.first.map(Array.init), ["ARRIRAW uncompressed", "2048x1152", "24 fps", "4"])
    }

    func testCameraSummaryGroupsUnknownCameraAsND() throws {
        try offload(to: bin)
        let cam = try table(try build([.cameraSummary]), .cameraSummary)
        XCTAssertEqual(cam.rows[0][0].display, "N/D")
        XCTAssertEqual(cam.rows[0][3].display, "4")
    }

    func testNotesOnlyWhenNotEmpty() throws {
        try offload(to: bin)
        XCTAssertNil(try build([.notes], notes: "  \n ").blocks.first)
        let doc = try build([.notes], notes: "Scheda A001 consegnata a Marco.\nSeconda riga")
        XCTAssertEqual(doc.blocks.first?.content, .text("Scheda A001 consegnata a Marco.\nSeconda riga"))
    }

    func testMismatchAppearsInReports() throws {
        let scan = try SourceScanner.scan(root: card.root)
        destinations = [base.appendingPathComponent("out", isDirectory: true)]
        let job = OffloadJob(sourceURL: card.root, destinationRoots: destinations)
        try store.beginOffload(jobID: job.id, binID: bin.id, sourcePath: card.root.path, destinations: [destinations[0].path])
        let engine = OffloadEngine(job: job, scan: scan)
        engine.onPhase = { phase in
            guard phase == .verifying else { return }
            let fd = open(self.destinations[0].appendingPathComponent("CLIP/C0001.MXF" + OffloadEngine.partialSuffix).path, O_RDWR)
            var b: UInt8 = 0; _ = pread(fd, &b, 1, 5); b ^= 1; _ = pwrite(fd, &b, 1, 5); close(fd)
        }
        try store.finishOffload(engine.run())
        let doc = try build([.shootingDay, .volume, .clipsOverview])
        XCTAssertTrue(try table(doc, .shootingDay).rows[0][5].display.contains("1 MISMATCH"))
        XCTAssertEqual(try keyValues(doc, .clipsOverview)["File MISMATCH"], "1")
        let vol = try XCTUnwrap(doc.blocks.first { $0.section == .volume })
        guard case .table(let t) = vol.content else { return XCTFail() }
        XCTAssertEqual(t.rows.first { $0[0].display == "C0001.MXF" }?[4].display, "MISMATCH")
    }
}
