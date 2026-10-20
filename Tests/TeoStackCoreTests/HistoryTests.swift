import XCTest
@testable import TeoStackCore

final class HistoryTests: XCTestCase {
    var store: ProjectStore!
    var card: FakeCard!
    var destBase: URL!

    override func setUpWithError() throws {
        store = try ProjectStore(path: nil)
        card = try FakeCard.create()
        destBase = try TestSupport.makeTempDir("dest")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: card.root.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: destBase)
    }

    private func titles(_ projectID: Int64) throws -> [String] {
        try store.history(projectID: projectID).map(\.title)
    }

    func testStructureOperationsAreLoggedNewestFirst() throws {
        let p = try store.createProject(name: "Film")
        let day = try store.createDay(projectID: p.id, name: "DAY01")
        let bin = try store.createBin(dayID: day.id, name: "A001")
        try store.renameNode(id: bin.id, to: "A002")
        try store.renameProject(id: p.id, to: "Film 2")
        try store.deleteNode(id: bin.id)

        let events = try store.history(projectID: p.id)
        XCTAssertEqual(events.map(\.kind), ["nodeDeleted", "projectRenamed", "nodeRenamed", "binCreated", "dayCreated", "projectCreated"])
        XCTAssertEqual(events.map(\.title), [
            "Bin «A002» eliminato",
            "Progetto rinominato: «Film» → «Film 2»",
            "Bin rinominato: «A001» → «A002»",
            "Bin «A001» creato in «DAY01»",
            "Cartella giorno «DAY01» creata",
            "Progetto «Film» creato",
        ])
        XCTAssertTrue(events[0].detail?.contains("NON") == false && events[0].detail?.contains("non sono stati toccati") == true)
        XCTAssertEqual(events[0].severity, .warning)
        XCTAssertTrue(zip(events, events.dropFirst()).allSatisfy { $0.date >= $1.date })
    }

    func testRenamingToSameNameLogsNothing() throws {
        let p = try store.createProject(name: "Film")
        let day = try store.createDay(projectID: p.id, name: "D1")
        let before = try store.history(projectID: p.id).count
        try store.renameProject(id: p.id, to: "Film")
        try store.renameNode(id: day.id, to: "D1")
        XCTAssertEqual(try store.history(projectID: p.id).count, before)
    }

    func testFailedOperationsAreNotLogged() throws {
        let p = try store.createProject(name: "Film")
        let day = try store.createDay(projectID: p.id, name: "D1")
        let before = try store.history(projectID: p.id).count
        XCTAssertThrowsError(try store.createDay(projectID: p.id, name: "d1"))
        XCTAssertThrowsError(try store.createBin(dayID: day.id, name: "a/b"))
        XCTAssertEqual(try store.history(projectID: p.id).count, before)
    }

    func testHistoryIsPerProject() throws {
        let a = try store.createProject(name: "A")
        let b = try store.createProject(name: "B")
        _ = try store.createDay(projectID: a.id, name: "DAY-A")
        XCTAssertEqual(try titles(b.id), ["Progetto «B» creato"])
        XCTAssertEqual(try titles(a.id).count, 2)
        try store.deleteProject(id: a.id)
        XCTAssertEqual(try store.history(projectID: a.id), [], "eliminando il progetto sparisce anche la sua cronologia")
        XCTAssertEqual(try titles(b.id), ["Progetto «B» creato"])
    }

    private func setupBin() throws -> (Project, TreeNode) {
        let p = try store.createProject(name: "Film")
        let bin = try store.createBin(dayID: try store.createDay(projectID: p.id, name: "DAY01").id, name: "A001")
        return (p, bin)
    }

    func testSuccessfulOffloadIsLoggedWithDetails() throws {
        let (p, bin) = try setupBin()
        let dest = destBase.appendingPathComponent("out")
        let scan = try SourceScanner.scan(root: card.root)
        let job = OffloadJob(sourceURL: card.root, destinationRoots: [dest])
        try store.beginOffload(jobID: job.id, binID: bin.id, sourcePath: card.root.path, destinations: [dest.path])
        let result = OffloadEngine(job: job, scan: scan).run()
        try store.logOffloadEvent(jobID: job.id, kind: "offloadCopyDone", title: "Copia completata")
        try store.finishOffload(result)

        let events = try store.history(projectID: p.id)
        XCTAssertEqual(Array(events.prefix(3).map(\.kind)), ["offloadCompleted", "offloadCopyDone", "offloadStarted"])
        let done = events[0]
        XCTAssertEqual(done.severity, .success)
        XCTAssertTrue(done.title.contains("\(card.files.count) file") && done.title.contains("tutti OK"), done.title)
        XCTAssertTrue(done.detail?.contains("XXH64") == true)
        let started = events[2]
        XCTAssertTrue(started.detail?.contains(card.root.path) == true && started.detail?.contains(dest.path) == true)
    }

    func testProblemsAreLoggedAsErrorsWithTheFileName() throws {
        let (p, bin) = try setupBin()
        let dest = destBase.appendingPathComponent("out")
        let scan = try SourceScanner.scan(root: card.root)
        let job = OffloadJob(sourceURL: card.root, destinationRoots: [dest])
        try store.beginOffload(jobID: job.id, binID: bin.id, sourcePath: card.root.path, destinations: [dest.path])
        let engine = OffloadEngine(job: job, scan: scan)
        engine.onPhase = { phase in
            guard phase == .verifying else { return }
            let fd = open(dest.appendingPathComponent("CLIP/C0001.MXF" + OffloadEngine.partialSuffix).path, O_RDWR)
            var b: UInt8 = 0; _ = pread(fd, &b, 1, 5); b ^= 1; _ = pwrite(fd, &b, 1, 5); close(fd)
        }
        try store.finishOffload(engine.run())
        let last = try XCTUnwrap(try store.history(projectID: p.id).first)
        XCTAssertEqual(last.kind, "offloadProblems")
        XCTAssertEqual(last.severity, .error)
        XCTAssertTrue(last.title.contains("1 MISMATCH"), last.title)
        XCTAssertTrue(last.detail?.contains("CLIP/C0001.MXF") == true)
    }

    func testCancelledResumedAndNotStartedOffloads() throws {
        let (p, bin) = try setupBin()
        let dest = destBase.appendingPathComponent("out")
        let scan = try SourceScanner.scan(root: card.root)
        let job = OffloadJob(sourceURL: card.root, destinationRoots: [dest])

        try store.beginOffload(jobID: job.id, binID: bin.id, sourcePath: card.root.path, destinations: [dest.path])
        let engine = OffloadEngine(job: job, scan: scan)
        var copied = 0
        engine.onFileUpdate = { if $0.status == .copied { copied += 1; if copied == 1 { engine.cancel() } } }
        try store.finishOffload(engine.run())
        XCTAssertEqual(try store.history(projectID: p.id).first?.kind, "offloadCancelled")
        XCTAssertEqual(try store.history(projectID: p.id).first?.severity, .warning)

        try store.beginOffload(jobID: job.id, binID: bin.id, sourcePath: card.root.path, destinations: [dest.path])
        XCTAssertEqual(try store.history(projectID: p.id).first?.kind, "offloadResumed")
        try store.finishOffload(OffloadEngine(job: job, scan: scan).run())
        XCTAssertEqual(try store.history(projectID: p.id).first?.kind, "offloadCompleted")

        let bad = OffloadJob(sourceURL: card.root, destinationRoots: [URL(fileURLWithPath: "/volume-inesistente/x")])
        try store.beginOffload(jobID: bad.id, binID: bin.id, sourcePath: card.root.path, destinations: ["/volume-inesistente/x"])
        try store.finishOffload(OffloadEngine(job: bad, scan: scan).run())
        let notStarted = try XCTUnwrap(try store.history(projectID: p.id).first)
        XCTAssertEqual(notStarted.kind, "offloadNotStarted")
        XCTAssertTrue(notStarted.detail?.contains("non raggiungibile") == true)
    }

    func testPersistsAcrossRestartAndFreeFormEvents() throws {
        let dir = try TestSupport.makeTempDir("db")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("t.sqlite").path
        var pid: Int64 = 0
        do {
            let s = try ProjectStore(path: path)
            pid = try s.createProject(name: "P").id
            try s.logEvent(projectID: pid, kind: "metadataRead", title: "Metadata letti", detail: "12 clip")
        }
        let events = try ProjectStore(path: path).history(projectID: pid)
        XCTAssertEqual(events.map(\.title), ["Metadata letti", "Progetto «P» creato"])
        XCTAssertEqual(events[0].detail, "12 clip")
        XCTAssertEqual(events[0].severity, .info)
    }
}
