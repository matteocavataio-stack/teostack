import XCTest
@testable import TeoStackCore

/// Verifica sovrapposta alla copia, sincronizzazione differita dei file piccoli e guasti a metà offload.
final class OffloadOverlapTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws { root = try TestSupport.makeTempDir("overlap") }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func makeCard(small: Int, bigMB: Int) throws -> URL {
        let card = root.appendingPathComponent("card")
        for i in 0..<small { try TestSupport.writeRandomFile(card.appendingPathComponent("SIDE/s\(String(format: "%03d", i)).xml"), size: 2_000 + i * 37, seed: UInt64(i)) }
        if bigMB > 0 { try TestSupport.writeRandomFile(card.appendingPathComponent("ZZ/last.mxf"), size: bigMB * 1_000_000, seed: 99) }
        return card
    }

    private func engine(_ card: URL, dests: [URL], configure: (inout OffloadEngine.Configuration) -> Void = { _ in }) throws -> OffloadEngine {
        for d in dests { try FileManager.default.createDirectory(at: d.deletingLastPathComponent(), withIntermediateDirectories: true) }
        var config = OffloadEngine.Configuration()
        configure(&config)
        return OffloadEngine(job: OffloadJob(sourceURL: card, destinationRoots: dests), scan: try SourceScanner.scan(root: card), configuration: config)
    }

    func testVerificationStartsWhileLaterFilesAreStillBeingCopied() throws {
        let card = try makeCard(small: 8, bigMB: 120)
        let dests = [root.appendingPathComponent("d1/A"), root.appendingPathComponent("d2/A")]
        let e = try engine(card, dests: dests) { $0.overlapVerification = true }
        let lock = NSLock()
        var events: [String] = []
        let lastIndex = e.scan.files.count - 1
        e.onFileUpdate = { u in
            guard u.destinationIndex == 0 else { return }
            lock.lock(); defer { lock.unlock() }
            if u.status == .ok && !events.contains("firstOK") { events.append("firstOK") }
            if u.status == .copying && u.fileIndex == lastIndex { events.append("lastCopying") }
        }
        let result = e.run()
        XCTAssertEqual(result.outcome, .completed)
        XCTAssertTrue(result.allOK)
        XCTAssertEqual(events.first, "firstOK", "un file piccolo dev'essere già stato verificato prima di iniziare l'ultimo file: \(events)")
        for d in dests { XCTAssertTrue(TestSupport.contentsEqual(card.appendingPathComponent("ZZ/last.mxf"), d.appendingPathComponent("ZZ/last.mxf"))) }
    }

    func testManySmallFilesWithDeferredSyncAreAllVerified() throws {
        let card = try makeCard(small: 400, bigMB: 0)
        let dests = [root.appendingPathComponent("d1/A"), root.appendingPathComponent("d2/A"), root.appendingPathComponent("d3/A")]
        for overlap in [true, false] {
            for d in dests { try? FileManager.default.removeItem(at: d.deletingLastPathComponent()) }
            let e = try engine(card, dests: dests) { $0.overlapVerification = overlap }
            let result = e.run()
            XCTAssertTrue(result.allOK, "overlap=\(overlap)")
            XCTAssertEqual(result.count(.ok, destination: 2), 400)
            for d in dests { XCTAssertTrue(TestSupport.allFiles(under: d).allSatisfy { !$0.hasSuffix(OffloadEngine.partialSuffix) }) }
        }
    }

    func testThresholdZeroStillWorks() throws {
        let card = try makeCard(small: 20, bigMB: 5)
        let e = try engine(card, dests: [root.appendingPathComponent("d1/A")]) { $0.deferredSyncThreshold = 0 }
        XCTAssertTrue(e.run().allOK)
    }

    func testDestinationDisappearingMidOffloadNeverGivesFalseOK() throws {
        let card = try makeCard(small: 30, bigMB: 40)
        let good = root.appendingPathComponent("good/A"), lost = root.appendingPathComponent("lost/A")
        let e = try engine(card, dests: [good, lost])
        var removed = false
        e.onFileUpdate = { u in
            if u.destinationIndex == 1, u.status == .copied, !removed {
                removed = true
                try? FileManager.default.removeItem(at: lost.deletingLastPathComponent())       // il disco "sparisce"
            }
        }
        let result = e.run()
        XCTAssertFalse(result.allOK)
        XCTAssertTrue(result.count(.ok, destination: 0) == result.files.count, "l'altra destinazione non viene toccata")
        for f in result.files where f.destinations[1].status == .ok {
            // un file dato per OK sulla destinazione sparita deve essere stato davvero riletto prima (e quindi esistere ora è impossibile)
            XCTAssertNotNil(f.destinations[1].destHash)
        }
        XCTAssertGreaterThan(result.count(.error, destination: 1) + result.count(.mismatch, destination: 1), 0, "la perdita del disco deve comparire come errore")
        XCTAssertFalse(FileManager.default.fileExists(atPath: lost.path), "nulla viene ricreato sul disco sparito")
    }

    func testCancelWhileVerificationOverlapsLeavesOnlyVerifiedIdenticalFiles() throws {
        let card = try makeCard(small: 40, bigMB: 60)
        let dests = [root.appendingPathComponent("d1/A")]
        let e = try engine(card, dests: dests)
        var copied = 0
        e.onFileUpdate = { u in if u.status == .copied { copied += 1; if copied == 30 { e.cancel() } } }
        let result = e.run()
        XCTAssertEqual(result.outcome, .cancelled)
        let files = TestSupport.allFiles(under: dests[0])
        XCTAssertTrue(files.allSatisfy { !$0.hasSuffix(OffloadEngine.partialSuffix) }, "\(files)")
        for f in result.files {
            let path = dests[0].appendingPathComponent(f.relativePath)
            if f.destinations[0].status == .ok {
                XCTAssertTrue(TestSupport.contentsEqual(card.appendingPathComponent(f.relativePath), path), "\(f.relativePath)")
            } else {
                XCTAssertFalse(FileManager.default.fileExists(atPath: path.path), "\(f.relativePath) non verificato ma presente")
            }
        }
    }

    func testResumeAfterCancelFinishesWithOverlap() throws {
        let card = try makeCard(small: 25, bigMB: 20)
        let dests = [root.appendingPathComponent("d1/A")]
        let first = try engine(card, dests: dests)
        var copied = 0
        first.onFileUpdate = { u in if u.status == .copied { copied += 1; if copied == 15 { first.cancel() } } }
        let r1 = first.run()
        XCTAssertEqual(r1.outcome, .cancelled)
        let journal = OffloadJournal(job: r1.job, state: .cancelled, files: r1.files, updatedAt: Date())
        for d in dests { try FileManager.default.createDirectory(at: d.deletingLastPathComponent(), withIntermediateDirectories: true) }
        let second = OffloadEngine(job: r1.job, scan: try SourceScanner.scan(root: card), resume: journal)
        let r2 = second.run()
        XCTAssertEqual(r2.outcome, .completed)
        XCTAssertTrue(r2.allOK)
        XCTAssertTrue(TestSupport.contentsEqual(card.appendingPathComponent("ZZ/last.mxf"), dests[0].appendingPathComponent("ZZ/last.mxf")))
    }
}
