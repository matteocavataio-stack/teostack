import XCTest
@testable import TeoStackCore

/// Sospendi/Continua, ripresa da metà file con punti di ripresa e avviso di blocco.
final class OffloadResumeTests: XCTestCase {
    var card: FakeCard!
    var destRoot: URL!
    var journalDir: URL!
    var store: JournalStore!
    let big = "A001R2EC/sub/deep/A001C003.ari"      // 20 000 001 byte

    override func setUpWithError() throws {
        card = try FakeCard.create()
        destRoot = try TestSupport.makeTempDir("dest")
        journalDir = try TestSupport.makeTempDir("journal")
        store = JournalStore(directory: journalDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: card.root.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: destRoot)
        try? FileManager.default.removeItem(at: journalDir)
    }

    private func dests(_ n: Int) -> [URL] {
        let list = (1...n).map { destRoot.appendingPathComponent("DISK\($0)/A001_CARD", isDirectory: true) }
        for d in list { try? FileManager.default.createDirectory(at: d.deletingLastPathComponent(), withIntermediateDirectories: true) }
        return list
    }

    private func engine(_ dests: [URL], resume: OffloadJournal? = nil, overlap: Bool = true,
                        configure: (inout OffloadEngine.Configuration) -> Void = { _ in }) throws -> OffloadEngine {
        var config = OffloadEngine.Configuration()
        config.chunkSize = 1 * 1024 * 1024
        config.verifyBufferSize = 1 * 1024 * 1024
        config.progressInterval = 0.05
        config.checkpointInterval = 2 * 1024 * 1024
        config.overlapVerification = overlap
        config.journalStore = store
        configure(&config)
        let scan = try SourceScanner.scan(root: card.root)
        let job = resume?.job ?? OffloadJob(sourceURL: card.root, destinationRoots: dests)
        return OffloadEngine(job: job, scan: scan, configuration: config, resume: resume)
    }

    private func assertIdenticalCopies(_ dests: [URL], file: StaticString = #filePath, line: UInt = #line) {
        for dest in dests {
            for f in card.files {
                XCTAssertTrue(TestSupport.contentsEqual(card.root.appendingPathComponent(f.path), dest.appendingPathComponent(f.path)), f.path, file: file, line: line)
            }
            XCTAssertTrue(TestSupport.allFiles(under: dest).allSatisfy { !$0.hasSuffix(OffloadEngine.partialSuffix) }, "nessun parziale rimasto", file: file, line: line)
        }
    }

    // MARK: Sospendi / Continua

    func testPauseStopsEverythingAndContinueFinishesWithAllFilesOK() throws {
        let d = dests(2)
        var snapshots: [OffloadSnapshot] = []
        let lock = NSLock()
        let eng = try engine(d) { $0.stallThreshold = 0.3 }
        eng.onSnapshot = { lock.lock(); snapshots.append($0); lock.unlock() }
        // pausa all'inizio della prima copia e ripresa da un altro thread dopo 0,8 s (più della soglia di blocco di 0,3 s)
        var paused = false
        eng.onFileUpdate = { u in
            if !paused, u.status == .copying { paused = true; eng.pause() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) { eng.resume() }
        let result = eng.run()
        XCTAssertTrue(result.allOK)
        assertIdenticalCopies(d)
        lock.lock(); defer { lock.unlock() }
        let pausedSnapshots = snapshots.filter { $0.isPaused }
        XCTAssertGreaterThan(pausedSnapshots.count, 3, "durante la pausa lo stato deve risultare «in pausa»")
        // in pausa nessun dato si muove: i byte letti restano fermi
        XCTAssertEqual(Set(pausedSnapshots.map { $0.readBytes }).count, 1, "in pausa non si legge nulla")
        XCTAssertFalse(snapshots.contains { $0.stall != nil }, "una pausa non è un blocco")
    }

    func testCancelWhilePausedStillStops() throws {
        let d = dests(1)
        let eng = try engine(d)
        var done = false
        eng.onFileUpdate = { u in if !done, u.status == .copying { done = true; eng.pause() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { eng.cancel() }
        let result = eng.run()
        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertTrue(TestSupport.allFiles(under: d[0]).allSatisfy { !$0.hasSuffix(OffloadEngine.partialSuffix) })
    }

    // MARK: Ripresa da metà file

    /// Sospende a metà del file grande, poi riprende: deve continuare dal punto di ripresa (non da zero) e dare file identici.
    func testSuspendKeepsPartialsAndResumeContinuesFromTheCheckpoint() throws {
        let d = dests(2)
        var firstEngine: OffloadEngine?
        let first = try engine(d) { c in
            c.afterChunk = { i, offset in
                if offset >= 7 * 1024 * 1024, firstEngine?.scan.files[i].relativePath == self.big { firstEngine?.suspend() }
            }
        }
        firstEngine = first
        let r1 = first.run()
        XCTAssertEqual(r1.outcome, .cancelled)
        let journal = try XCTUnwrap(store.latestResumable())
        let item = try XCTUnwrap(journal.files.first { $0.relativePath == big })
        let cp = try XCTUnwrap(item.checkpoint, "il file grande deve avere un punto di ripresa")
        XCTAssertGreaterThanOrEqual(cp.offset, 7 * 1024 * 1024)
        XCTAssertLessThan(cp.offset, 20_000_001)
        for dest in d {
            let partial = dest.appendingPathComponent(big + OffloadEngine.partialSuffix).path
            XCTAssertTrue(FileManager.default.fileExists(atPath: partial), "il file parziale deve restare")
        }

        var firstOffsetInBigFile: Int64?
        var second: OffloadEngine?
        second = try engine(d, resume: journal) { c in
            c.afterChunk = { i, offset in
                if second?.scan.files[i].relativePath == self.big, firstOffsetInBigFile == nil { firstOffsetInBigFile = offset }
            }
        }
        let r2 = second!.run()
        XCTAssertTrue(r2.allOK)
        XCTAssertEqual(firstOffsetInBigFile, cp.offset + 1024 * 1024, "la sorgente deve essere riletta solo dal punto di ripresa")
        assertIdenticalCopies(d)
        XCTAssertNil(store.latestResumable())
        let finalJournalChecks = try store.load(id: journal.job.id)
        XCTAssertTrue(finalJournalChecks.files.allSatisfy { $0.checkpoint == nil }, "a file concluso non resta nessun punto di ripresa")
    }

    /// Un byte alterato nella parte già scritta: la ripresa se ne accorge (rilettura dal disco) e il file riparte da zero.
    func testCorruptedPartialIsDetectedAndFileRestartsFromZero() throws {
        let d = dests(1)
        var firstEngine: OffloadEngine?
        let first = try engine(d) { c in
            c.afterChunk = { i, offset in
                if offset >= 7 * 1024 * 1024, firstEngine?.scan.files[i].relativePath == self.big { firstEngine?.suspend() }
            }
        }
        firstEngine = first
        _ = first.run()
        let journal = try XCTUnwrap(store.latestResumable())
        XCTAssertNotNil(journal.files.first { $0.relativePath == big }?.checkpoint)
        // altero un byte nei primi 3 MB del parziale
        let partial = d[0].appendingPathComponent(big + OffloadEngine.partialSuffix)
        let handle = try FileHandle(forUpdating: partial)
        try handle.seek(toOffset: 1_500_000)
        let original = try XCTUnwrap(try handle.read(upToCount: 1))
        try handle.seek(toOffset: 1_500_000)
        try handle.write(contentsOf: Data([original[0] ^ 0xFF]))
        try handle.close()

        var firstOffset: Int64?
        var second: OffloadEngine?
        second = try engine(d, resume: journal) { c in
            c.afterChunk = { i, offset in
                if second?.scan.files[i].relativePath == self.big, firstOffset == nil { firstOffset = offset }
            }
        }
        let r2 = second!.run()
        XCTAssertTrue(r2.allOK, "il file riparte da zero e viene verificato")
        XCTAssertEqual(firstOffset, 1024 * 1024, "senza un punto di ripresa valido si ricomincia dall'inizio del file")
        assertIdenticalCopies(d)
    }

    /// La sorgente è cambiata dopo l'interruzione: nessuna ripresa da metà file.
    func testChangedSourceDoesNotResumeFromTheMiddle() throws {
        let d = dests(1)
        var firstEngine: OffloadEngine?
        let first = try engine(d) { c in
            c.afterChunk = { i, offset in
                if offset >= 7 * 1024 * 1024, firstEngine?.scan.files[i].relativePath == self.big { firstEngine?.suspend() }
            }
        }
        firstEngine = first
        _ = first.run()
        let journal = try XCTUnwrap(store.latestResumable())
        // il file della sorgente viene modificato (stessa dimensione, data diversa)
        let src = card.root.appendingPathComponent(big)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: src.path)
        var firstOffset: Int64?
        var second: OffloadEngine?
        second = try engine(d, resume: journal) { c in
            c.afterChunk = { i, offset in
                if second?.scan.files[i].relativePath == self.big, firstOffset == nil { firstOffset = offset }
            }
        }
        let r2 = second!.run()
        XCTAssertEqual(firstOffset, 1024 * 1024)
        XCTAssertTrue(r2.files.first { $0.relativePath == big }?.destinations[0].status == .ok)
    }

    /// Copia già completa ma non ancora verificata al momento dell'interruzione: la ripresa verifica soltanto, senza rileggere la sorgente.
    func testResumeVerifiesCompletePartialsWithoutReadingTheSourceAgain() throws {
        let d = dests(1)
        var firstEngine: OffloadEngine?
        let first = try engine(d, overlap: false)
        firstEngine = first
        first.onPhase = { if $0 == .verifying { firstEngine?.suspend() } }
        let r1 = first.run()
        XCTAssertEqual(r1.outcome, .cancelled)
        let journal = try XCTUnwrap(store.latestResumable())
        XCTAssertTrue(journal.files.filter { $0.size > 0 }.allSatisfy { $0.sourceHash != nil })

        var chunksRead = 0
        let second = try engine(d, resume: journal, overlap: false) { c in
            c.afterChunk = { _, _ in chunksRead += 1 }
        }
        let r2 = second.run()
        XCTAssertTrue(r2.allOK)
        XCTAssertEqual(chunksRead, 0, "nessun file deve essere riletto dalla sorgente: erano già tutti copiati interamente")
        assertIdenticalCopies(d)
    }

    func testCancelStillRemovesEverythingIncludingCheckpoints() throws {
        let d = dests(1)
        var firstEngine: OffloadEngine?
        let first = try engine(d) { c in
            c.afterChunk = { i, offset in
                if offset >= 7 * 1024 * 1024, firstEngine?.scan.files[i].relativePath == self.big { firstEngine?.cancel() }
            }
        }
        firstEngine = first
        let r = first.run()
        XCTAssertEqual(r.outcome, .cancelled)
        XCTAssertTrue(TestSupport.allFiles(under: d[0]).allSatisfy { !$0.hasSuffix(OffloadEngine.partialSuffix) })
        XCTAssertTrue(r.files.allSatisfy { $0.checkpoint == nil })
        let journal = try XCTUnwrap(store.latestResumable())
        XCTAssertTrue(journal.files.allSatisfy { $0.checkpoint == nil })
    }

    // MARK: Avviso di blocco

    func testSlowDestinationRaisesAStallWarningAndStillFinishes() throws {
        let d = dests(1)
        var slowed = false
        let eng = try engine(d) { c in
            c.stallThreshold = 0.3
            c.duringWrite = { _ in
                if !slowed { slowed = true; Thread.sleep(forTimeInterval: 1.0) }   // un disco che per un secondo non risponde
            }
        }
        var warnings: [StallWarning] = []
        let lock = NSLock()
        eng.onSnapshot = { s in if let w = s.stall { lock.lock(); warnings.append(w); lock.unlock() } }
        let result = eng.run()
        XCTAssertTrue(result.allOK)
        lock.lock(); defer { lock.unlock() }
        let w = try XCTUnwrap(warnings.first, "il disco fermo per 1 s con soglia 0,3 s deve produrre un avviso")
        XCTAssertEqual(w.kind, .destinationWrite(0))
        XCTAssertGreaterThanOrEqual(w.seconds, 0.3)
        XCTAssertTrue(w.message.contains("1"), w.message)
    }

    func testNoStallWarningOnANormalOffload() throws {
        let d = dests(1)
        let eng = try engine(d)
        var any = false
        eng.onSnapshot = { if $0.stall != nil { any = true } }
        _ = eng.run()
        XCTAssertFalse(any)
    }

    func testHasherStateRoundTrip() {
        let a = XXH64Hasher()
        a.update(Data(repeating: 7, count: 100_003))
        let state = try! XCTUnwrap(a.exportState())
        a.update(Data(repeating: 9, count: 55_555))
        let b = XXH64Hasher()
        XCTAssertTrue(b.restore(state))
        b.update(Data(repeating: 9, count: 55_555))
        XCTAssertEqual(a.hexDigest(), b.hexDigest())
        XCTAssertFalse(b.restore(Data([1, 2, 3])), "uno stato di dimensione sbagliata non si accetta")
    }
}

final class FileVerifierCancelTests: XCTestCase {
    /// Annullare la lettura mentre il lettore ha già riempito tutti i buffer non deve far crollare il programma
    /// (libdispatch: «Semaphore object deallocated while in use» se il semaforo dei buffer torna con un valore troppo basso).
    func testCancellingWhileTheReaderIsAheadDoesNotCrash() throws {
        let dir = try TestSupport.makeTempDir("verifier")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("big.bin")
        try TestSupport.writeRandomFile(file, size: 12 * 1024 * 1024, seed: 99)
        for _ in 0..<5 {
            XCTAssertThrowsError(try FileVerifier.hash(path: file.path, uncached: true, bufferSize: 1024 * 1024,
                                                       isCancelled: { Thread.sleep(forTimeInterval: 0.05); return true })) { error in
                XCTAssertTrue(error is CancellationError)
            }
        }
    }
}
