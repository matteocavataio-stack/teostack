import XCTest
@testable import TeoStackCore

/// La cronologia registra SOLO gli offload completati con tutti i file OK (scelta dell'utente).
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

    private func setupBin(_ project: String = "Film") throws -> (Project, TreeNode) {
        let p = try store.createProject(name: project)
        let bin = try store.createBin(parentID: try store.createDay(projectID: p.id, name: "DAY01").id, name: "a001")
        return (p, bin)
    }

    @discardableResult
    private func runOffload(bin: TreeNode, to dest: URL, corrupt: String? = nil, cancelAfterFirstCopy: Bool = false,
                            dests: [URL]? = nil) throws -> OffloadResult {
        let roots = dests ?? [dest]
        let scan = try SourceScanner.scan(root: card.root)
        let job = OffloadJob(sourceURL: card.root, destinationRoots: roots)
        try store.beginOffload(jobID: job.id, binID: bin.id, sourcePath: card.root.path, destinations: roots.map(\.path))
        let engine = OffloadEngine(job: job, scan: scan)
        if let corrupt {
            engine.onPhase = { phase in
                guard phase == .verifying else { return }
                let fd = open(dest.appendingPathComponent(corrupt + OffloadEngine.partialSuffix).path, O_RDWR)
                var b: UInt8 = 0; _ = pread(fd, &b, 1, 5); b ^= 1; _ = pwrite(fd, &b, 1, 5); close(fd)
            }
        }
        if cancelAfterFirstCopy {
            engine.onFileUpdate = { if $0.status == .copied { engine.cancel() } }
        }
        let result = engine.run()
        try store.finishOffload(result)
        return result
    }

    func testOnlyTheCompletedOffloadIsRecorded() throws {
        let (p, bin) = try setupBin()
        XCTAssertEqual(try store.history(projectID: p.id), [], "creare progetto, giorno e bin non registra nulla")
        let result = try runOffload(bin: bin, to: destBase.appendingPathComponent("out"))
        XCTAssertTrue(result.allOK)

        let events = try store.history(projectID: p.id)
        XCTAssertEqual(events.count, 1)
        let e = try XCTUnwrap(events.first)
        XCTAssertEqual(e.kind, "offloadCompleted")
        XCTAssertEqual(e.severity, .success)
        XCTAssertTrue(e.title.hasPrefix("Offload completato nel bin «a001»: \(card.files.count) file, "), e.title)
        XCTAssertTrue(e.title.hasSuffix("tutti OK"), e.title)
        XCTAssertTrue(e.detail?.contains("XXH64 identico alla sorgente su 1 destinazione/i") == true, e.detail ?? "")
        XCTAssertTrue(e.detail?.contains("Durata") == true)
    }

    func testNothingElseIsRecorded() throws {
        let (p, bin) = try setupBin()
        let day = try XCTUnwrap(try store.tree(projectID: p.id).children?.first)
        try store.renameNode(id: bin.id, to: "a002")
        try store.renameProject(id: p.id, to: "Film 2")
        try store.createBin(parentID: day.id, name: "extra")
        try store.deleteNode(id: try XCTUnwrap(try store.tree(projectID: p.id).children?.first?.children?.first { $0.name == "extra" }?.id))
        XCTAssertEqual(try store.history(projectID: p.id), [])
    }

    func testProblemCancelledAndNotStartedOffloadsAreNotRecorded() throws {
        let (p, bin) = try setupBin()
        let out = destBase.appendingPathComponent("out")
        let bad = try runOffload(bin: bin, to: out, corrupt: "CLIP/C0001.MXF")
        XCTAssertFalse(bad.allOK)
        let cancelled = try runOffload(bin: bin, to: destBase.appendingPathComponent("out2"), cancelAfterFirstCopy: true)
        XCTAssertEqual(cancelled.outcome, .cancelled)
        let unreachable = try runOffload(bin: bin, to: URL(fileURLWithPath: "/volume-inesistente/x"))
        XCTAssertEqual(unreachable.outcome, .preflightFailed)
        XCTAssertEqual(try store.history(projectID: p.id), [])
    }

    func testEachCompletedOffloadAddsOneEntryNewestFirst() throws {
        let (p, bin) = try setupBin()
        try runOffload(bin: bin, to: destBase.appendingPathComponent("a"))
        Thread.sleep(forTimeInterval: 0.01)
        try runOffload(bin: bin, to: destBase.appendingPathComponent("b"))
        let events = try store.history(projectID: p.id)
        XCTAssertEqual(events.count, 2)
        XCTAssertGreaterThanOrEqual(events[0].date, events[1].date)
    }

    func testHistoryIsPerProjectAndRemovedWithTheProject() throws {
        let (a, binA) = try setupBin("A")
        let (b, _) = try setupBin("B")
        try runOffload(bin: binA, to: destBase.appendingPathComponent("a"))
        XCTAssertEqual(try store.history(projectID: a.id).count, 1)
        XCTAssertEqual(try store.history(projectID: b.id).count, 0)
        try store.deleteProject(id: a.id)
        XCTAssertEqual(try store.history(projectID: a.id), [])
    }

    func testResumedOffloadThatCompletesIsRecordedOnce() throws {
        let (p, bin) = try setupBin()
        let dest = destBase.appendingPathComponent("out")
        let scan = try SourceScanner.scan(root: card.root)
        let job = OffloadJob(sourceURL: card.root, destinationRoots: [dest])
        try store.beginOffload(jobID: job.id, binID: bin.id, sourcePath: card.root.path, destinations: [dest.path])
        let engine = OffloadEngine(job: job, scan: scan)
        engine.onFileUpdate = { if $0.status == .copied { engine.cancel() } }
        try store.finishOffload(engine.run())
        XCTAssertEqual(try store.history(projectID: p.id), [])
        try store.beginOffload(jobID: job.id, binID: bin.id, sourcePath: card.root.path, destinations: [dest.path])
        try store.finishOffload(OffloadEngine(job: job, scan: scan).run())
        XCTAssertEqual(try store.history(projectID: p.id).count, 1)
    }

    func testPersistsAcrossRestart() throws {
        let dir = try TestSupport.makeTempDir("db")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("t.sqlite").path
        var pid: Int64 = 0
        do {
            let s = try ProjectStore(path: path)
            let p = try s.createProject(name: "P")
            pid = p.id
            let bin = try s.createBin(parentID: try s.createDay(projectID: p.id, name: "D").id, name: "B")
            let scan = try SourceScanner.scan(root: card.root)
            let job = OffloadJob(sourceURL: card.root, destinationRoots: [destBase.appendingPathComponent("o")])
            try s.beginOffload(jobID: job.id, binID: bin.id, sourcePath: card.root.path, destinations: [])
            try s.finishOffload(OffloadEngine(job: job, scan: scan).run())
        }
        XCTAssertEqual(try ProjectStore(path: path).history(projectID: pid).count, 1)
    }

    func testOnlyCompletedKindIsEnabled() {
        XCTAssertEqual(ProjectStore.recordedEventKinds, ["offloadCompleted"])
    }

    func testClearHistoryOnlyRemovesThisProjectsEvents() throws {
        let (p1, bin1) = try setupBin("Uno")
        let (p2, bin2) = try setupBin("Due")
        try runOffload(bin: bin1, to: destBase.appendingPathComponent("a"))
        try runOffload(bin: bin2, to: destBase.appendingPathComponent("b"))
        XCTAssertEqual(try store.history(projectID: p1.id).count, 1)
        XCTAssertEqual(try store.history(projectID: p2.id).count, 1)

        XCTAssertEqual(try store.clearHistory(projectID: p1.id), 1)
        XCTAssertTrue(try store.history(projectID: p1.id).isEmpty)
        XCTAssertEqual(try store.history(projectID: p2.id).count, 1, "gli altri progetti non cambiano")
        XCTAssertFalse(try store.clips(underNode: bin1.id).isEmpty, "i clip e gli offload restano")
        XCTAssertEqual(try store.offloads(binID: bin1.id).count, 1)
        XCTAssertEqual(try store.clearHistory(projectID: p1.id), 0, "già vuota")
    }
}
