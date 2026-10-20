import XCTest
@testable import TeoStackCore

final class OffloadEngineTests: XCTestCase {
    var card: FakeCard!
    var destRoot: URL!
    var dests: [URL] = []

    override func setUpWithError() throws {
        card = try FakeCard.create()
        destRoot = try TestSupport.makeTempDir("dest")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: card.root.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: destRoot)
    }

    private func makeDests(_ n: Int) -> [URL] {
        dests = (1...n).map { destRoot.appendingPathComponent("DISK\($0)/A001_CARD", isDirectory: true) }
        for d in dests { try? FileManager.default.createDirectory(at: d.deletingLastPathComponent(), withIntermediateDirectories: true) }
        return dests
    }

    private func makeEngine(dests: [URL], bases: [URL]? = nil, resume: OffloadJournal? = nil,
                            configure: (inout OffloadEngine.Configuration) -> Void = { _ in }) throws -> OffloadEngine {
        var config = OffloadEngine.Configuration()
        config.chunkSize = 1 * 1024 * 1024          // più chunk per file nei test
        config.verifyBufferSize = 1 * 1024 * 1024
        config.progressInterval = 0.05
        configure(&config)
        let scan = try SourceScanner.scan(root: card.root)
        let job = resume?.job ?? OffloadJob(sourceURL: card.root, destinationRoots: dests, destinationBases: bases)
        return OffloadEngine(job: job, scan: scan, configuration: config, resume: resume)
    }

    // MARK: Caso felice

    func testOffloadToThreeDestinationsAllOKAndIdentical() throws {
        let dests = makeDests(3)
        let before = try TestSupport.snapshot(of: card.root)
        let engine = try makeEngine(dests: dests)
        var snapshots: [OffloadSnapshot] = []
        let lock = NSLock()
        engine.onSnapshot = { lock.lock(); snapshots.append($0); lock.unlock() }

        let result = engine.run()

        XCTAssertEqual(result.outcome, .completed)
        XCTAssertTrue(result.allOK)
        XCTAssertEqual(result.files.count, card.files.count)
        for f in card.files {
            let src = card.root.appendingPathComponent(f.path)
            let expectedHash = try TestSupport.xxhsumHash(of: src)
            let fr = try XCTUnwrap(result.files.first { $0.relativePath == f.path })
            XCTAssertEqual(fr.sourceHash, expectedHash, "hash sorgente \(f.path)")
            for (d, dest) in dests.enumerated() {
                let copy = dest.appendingPathComponent(f.path)
                XCTAssertEqual(fr.destinations[d].status, .ok, "\(f.path) dest \(d)")
                XCTAssertEqual(fr.destinations[d].destHash, expectedHash)
                XCTAssertTrue(TestSupport.contentsEqual(src, copy), "contenuto \(f.path) dest \(d)")
                XCTAssertEqual(try TestSupport.xxhsumHash(of: copy), expectedHash)
                // date originali mantenute
                let s = try DiskIO.lstatInfo(path: src.path), c = try DiskIO.lstatInfo(path: copy.path)
                XCTAssertEqual(s.times.modification.timeIntervalSince1970, c.times.modification.timeIntervalSince1970, accuracy: 0.001)
            }
        }
        // nessun file temporaneo rimasto
        for dest in dests {
            XCTAssertTrue(TestSupport.allFiles(under: dest).allSatisfy { !$0.hasSuffix(OffloadEngine.partialSuffix) })
        }
        // la sorgente non è stata toccata
        XCTAssertEqual(try TestSupport.snapshot(of: card.root), before)
        // avanzamento: l'ultimo snapshot è completo e ci sono velocità misurate
        lock.lock(); defer { lock.unlock() }
        let last = try XCTUnwrap(snapshots.last)
        XCTAssertEqual(last.phase, .finished)
        XCTAssertEqual(last.destinations.count, 3)
        XCTAssertEqual(last.readBytes, last.totalBytes)
        for p in last.destinations {
            XCTAssertEqual(p.writtenBytes, p.totalBytes)
            XCTAssertEqual(p.verifiedBytes, p.totalBytes)
            XCTAssertEqual(p.okCount, card.files.count)
        }
    }

    func testDirectoryDatesArePreserved() throws {
        let dests = makeDests(1)
        let dir = card.root.appendingPathComponent("A001R2EC/sub")
        let date = Date(timeIntervalSince1970: 1_650_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: dir.path)
        let result = try makeEngine(dests: dests).run()
        XCTAssertTrue(result.allOK)
        let info = try DiskIO.lstatInfo(path: dests[0].appendingPathComponent("A001R2EC/sub").path)
        XCTAssertEqual(info.times.modification.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: File corrotto di proposito

    func testCorruptedDestinationFileIsReportedAsMismatchAndNeverGetsFinalName() throws {
        let dests = makeDests(3)
        let engine = try makeEngine(dests: dests)
        let target = "A001R2EC/sub/deep/A001C003.ari"
        engine.onPhase = { phase in
            guard phase == .verifying else { return }
            // Corrompe un solo byte nella destinazione 2 dopo la copia e prima della rilettura.
            let tmp = dests[1].appendingPathComponent(target + OffloadEngine.partialSuffix).path
            let fd = open(tmp, O_RDWR)
            XCTAssertGreaterThanOrEqual(fd, 0)
            var byte: UInt8 = 0
            XCTAssertEqual(pread(fd, &byte, 1, 12_345), 1)
            byte ^= 0x01
            XCTAssertEqual(pwrite(fd, &byte, 1, 12_345), 1)
            close(fd)
        }
        let result = engine.run()
        XCTAssertEqual(result.outcome, .completed)
        XCTAssertFalse(result.allOK, "con un file corrotto non deve mai risultare tutto OK")
        let fr = try XCTUnwrap(result.files.first { $0.relativePath == target })
        XCTAssertEqual(fr.destinations[0].status, .ok)
        XCTAssertEqual(fr.destinations[1].status, .mismatch)
        XCTAssertEqual(fr.destinations[2].status, .ok)
        XCTAssertNotEqual(fr.destinations[1].destHash, fr.sourceHash)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dests[1].appendingPathComponent(target).path),
                       "un file MISMATCH non deve avere il nome definitivo")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dests[1].appendingPathComponent(target + OffloadEngine.partialSuffix).path))
        XCTAssertEqual(result.count(.mismatch, destination: 1), 1)
        XCTAssertEqual(result.count(.ok, destination: 1), card.files.count - 1)
        XCTAssertEqual(result.count(.mismatch, destination: 0), 0)
    }

    func testTruncatedDestinationFileIsMismatch() throws {
        let dests = makeDests(1)
        let engine = try makeEngine(dests: dests)
        let target = "CLIP/C0001.MXF"
        engine.onPhase = { phase in
            if phase == .verifying {
                XCTAssertEqual(truncate(dests[0].appendingPathComponent(target + OffloadEngine.partialSuffix).path, 4_000_000), 0)
            }
        }
        let result = engine.run()
        let fr = try XCTUnwrap(result.files.first { $0.relativePath == target })
        XCTAssertEqual(fr.destinations[0].status, .mismatch)
        XCTAssertFalse(result.allOK)
    }

    // MARK: Destinazione già presente

    func testExistingIdenticalFileIsVerifiedNotRewritten() throws {
        let dests = makeDests(1)
        XCTAssertTrue(try makeEngine(dests: dests).run().allOK)
        let file = dests[0].appendingPathComponent("CLIP/C0001.MXF")
        let before = try DiskIO.lstatInfo(path: file.path)
        // seconda esecuzione sulla stessa destinazione
        let second = try makeEngine(dests: dests).run()
        XCTAssertTrue(second.allOK)
        let after = try DiskIO.lstatInfo(path: file.path)
        XCTAssertEqual(before.times.modification, after.times.modification)
        let fr = try XCTUnwrap(second.files.first { $0.relativePath == "CLIP/C0001.MXF" })
        XCTAssertNotNil(fr.destinations[0].message)
    }

    func testExistingDifferentFileIsNeverOverwritten() throws {
        let dests = makeDests(1)
        let victim = dests[0].appendingPathComponent("CLIP/C0001M01.XML")
        try FileManager.default.createDirectory(at: victim.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("contenuto diverso".utf8).write(to: victim)
        let result = try makeEngine(dests: dests).run()
        XCTAssertFalse(result.allOK)
        let fr = try XCTUnwrap(result.files.first { $0.relativePath == "CLIP/C0001M01.XML" })
        XCTAssertEqual(fr.destinations[0].status, .mismatch)
        XCTAssertEqual(try Data(contentsOf: victim), Data("contenuto diverso".utf8), "il file esistente non va toccato")
    }

    // MARK: Errori

    func testSourceFileVanishingGivesErrorNotFalseOK() throws {
        let dests = makeDests(2)
        let scan = try SourceScanner.scan(root: card.root)
        try FileManager.default.removeItem(at: card.root.appendingPathComponent("CLIP/C0001.MXF"))
        let job = OffloadJob(sourceURL: card.root, destinationRoots: dests)
        var config = OffloadEngine.Configuration(); config.chunkSize = 1_048_576
        let result = OffloadEngine(job: job, scan: scan, configuration: config).run()
        XCTAssertFalse(result.allOK)
        let fr = try XCTUnwrap(result.files.first { $0.relativePath == "CLIP/C0001.MXF" })
        XCTAssertNil(fr.sourceHash)
        for d in 0..<2 {
            XCTAssertEqual(fr.destinations[d].status, .error)
            XCTAssertNotNil(fr.destinations[d].message)
            XCTAssertFalse(FileManager.default.fileExists(atPath: dests[d].appendingPathComponent("CLIP/C0001.MXF").path))
        }
        XCTAssertEqual(result.count(.ok, destination: 0), card.files.count - 1)
    }

    func testSourceFileChangingSizeIsAnError() throws {
        let dests = makeDests(1)
        let scan = try SourceScanner.scan(root: card.root)
        let handle = try FileHandle(forWritingTo: card.root.appendingPathComponent("tiny.txt"))
        try handle.seekToEnd(); try handle.write(contentsOf: Data("more".utf8)); try handle.close()
        let job = OffloadJob(sourceURL: card.root, destinationRoots: dests)
        let result = OffloadEngine(job: job, scan: scan).run()
        let fr = try XCTUnwrap(result.files.first { $0.relativePath == "tiny.txt" })
        XCTAssertEqual(fr.destinations[0].status, .error)
        XCTAssertFalse(result.allOK)
    }

    func testInsufficientSpaceStopsBeforeCopying() throws {
        let dests = makeDests(2)
        let engine = try makeEngine(dests: dests) { $0.freeSpaceProvider = { url in url.path.contains("DISK2") ? 1_000 : 10_000_000_000 } }
        let result = engine.run()
        XCTAssertEqual(result.outcome, .preflightFailed)
        XCTAssertFalse(result.allOK)
        XCTAssertTrue(result.preflightErrors.contains { $0.contains("Destinazione 2") && $0.contains("spazio insufficiente") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: dests[0].path), "nessuna copia deve essere iniziata")
    }

    /// Struttura progetto: la base (disco) esiste, Progetto/Giorno/Bin no e vengono creati.
    func testMissingProjectFoldersUnderExistingBaseAreCreated() throws {
        let base = destRoot.appendingPathComponent("DISCO")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = base.appendingPathComponent("Film/DAY01_20261020/A001", isDirectory: true)
        let result = try makeEngine(dests: [root], bases: [base]).run()
        XCTAssertEqual(result.outcome, .completed)
        XCTAssertTrue(result.allOK)
        XCTAssertTrue(TestSupport.contentsEqual(card.root.appendingPathComponent("CLIP/C0001.MXF"), root.appendingPathComponent("CLIP/C0001.MXF")))
    }

    func testMissingBaseMeansDiskUnplugged() throws {
        let base = destRoot.appendingPathComponent("DISCO-SCOLLEGATO")     // non esiste
        let root = base.appendingPathComponent("Film/DAY01/A001", isDirectory: true)
        let result = try makeEngine(dests: [root], bases: [base]).run()
        XCTAssertEqual(result.outcome, .preflightFailed)
        XCTAssertTrue(result.preflightErrors.first?.contains("non è raggiungibile") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path), "non deve creare la base al posto del disco")
    }

    func testDestinationOutsideBaseIsRefused() throws {
        let base = destRoot.appendingPathComponent("DISCO")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let result = try makeEngine(dests: [destRoot.appendingPathComponent("ALTROVE/x")], bases: [base]).run()
        XCTAssertEqual(result.outcome, .preflightFailed)
    }

    func testCancelRemovesFoldersCreatedUnderBase() throws {
        let base = destRoot.appendingPathComponent("DISCO")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = base.appendingPathComponent("Film/DAY01/A001", isDirectory: true)
        let engine = try makeEngine(dests: [root], bases: [base])
        var copied = 0
        engine.onFileUpdate = { if $0.status == .copied { copied += 1; if copied == 2 { engine.cancel() } } }
        XCTAssertEqual(engine.run().outcome, .cancelled)
        XCTAssertEqual(TestSupport.allFiles(under: base), [], "Annulla deve togliere anche Film/DAY01/A001 create dall'offload")
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.path), "la cartella base scelta dall'utente resta")
    }

    func testUnreachableDestinationStopsBeforeCopying() throws {
        let missing = URL(fileURLWithPath: "/Volumes-inesistente/DISK/A001_CARD")
        let result = try makeEngine(dests: [missing]).run()
        XCTAssertEqual(result.outcome, .preflightFailed)
        XCTAssertTrue(result.preflightErrors.first?.contains("non raggiungibile") == true)
    }

    func testDestinationInsideSourceIsRefused() throws {
        let result = try makeEngine(dests: [card.root.appendingPathComponent("copia")]).run()
        XCTAssertEqual(result.outcome, .preflightFailed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: card.root.appendingPathComponent("copia").path))
    }

    func testErrorClassificationAndItalianMessages() {
        XCTAssertTrue(DiskIOError(code: ENOSPC, operation: "x", path: "y").isFatalForDestination)
        XCTAssertTrue(DiskIOError(code: ENXIO, operation: "x", path: "y").isFatalForDestination)
        XCTAssertFalse(DiskIOError(code: ENOENT, operation: "x", path: "y").isFatalForDestination)
        XCTAssertTrue(DiskIOError(code: ENOSPC, operation: "Scrittura", path: "/Volumes/X/f").description.contains("spazio insufficiente"))
        XCTAssertTrue(DiskIOError(code: ENXIO, operation: "Scrittura", path: "/Volumes/X/f").description.contains("scollegato"))
        XCTAssertTrue(DiskIOError(code: EIO, operation: "Lettura", path: "/Volumes/X/f").description.contains("input/output"))
    }

    /// Disco pieno DURANTE la copia (volume minuscolo montato solo per il test; Linux, richiede root).
    func testDiskFullDuringCopyKillsOnlyThatDestination() throws {
        #if os(Linux)
        let small = destRoot.appendingPathComponent("SMALL")
        try FileManager.default.createDirectory(at: small, withIntermediateDirectories: true)
        let mount = Process()
        mount.executableURL = URL(fileURLWithPath: "/bin/mount")
        mount.arguments = ["-t", "tmpfs", "-o", "size=8m", "tmpfs", small.path]
        try? mount.run(); mount.waitUntilExit()
        guard mount.terminationStatus == 0 else { throw XCTSkip("mount tmpfs non permesso in questo ambiente") }
        defer { let u = Process(); u.executableURL = URL(fileURLWithPath: "/bin/umount"); u.arguments = [small.path]; try? u.run(); u.waitUntilExit() }

        let good = destRoot.appendingPathComponent("GOOD/A001_CARD")
        try FileManager.default.createDirectory(at: good.deletingLastPathComponent(), withIntermediateDirectories: true)
        let engine = try makeEngine(dests: [good, small.appendingPathComponent("A001_CARD")]) {
            $0.freeSpaceProvider = { _ in 100_000_000_000 }    // finge di avere spazio: l'errore arriva in scrittura
        }
        let result = engine.run()
        XCTAssertFalse(result.allOK)
        XCTAssertEqual(result.count(.ok, destination: 0), card.files.count)
        XCTAssertNotNil(result.destinationErrors[1])
        XCTAssertTrue(result.destinationErrors[1]?.contains("spazio insufficiente") == true)
        XCTAssertTrue(result.files.contains { $0.destinations[1].status == .error })
        XCTAssertNil(result.destinationErrors[0])
        // nessun parziale sul volume pieno
        XCTAssertTrue(TestSupport.allFiles(under: small).allSatisfy { !$0.hasSuffix(OffloadEngine.partialSuffix) })
        #else
        throw XCTSkip("test eseguibile solo su Linux")
        #endif
    }

    // MARK: Annulla e Riprendi

    func testCancelRemovesPartialFilesAndLeavesNothingBehind() throws {
        let dests = makeDests(2)
        let engine = try makeEngine(dests: dests)
        var copied = 0
        engine.onFileUpdate = { update in
            if update.status == .copied { copied += 1; if copied == 2 { engine.cancel() } }
        }
        let result = engine.run()
        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertFalse(result.allOK)
        for dest in dests {
            XCTAssertEqual(TestSupport.allFiles(under: dest), [], "dopo Annulla non devono restare file o cartelle create")
        }
        XCTAssertTrue(result.files.allSatisfy { $0.destinations.allSatisfy { $0.status == .pending } })
    }

    func testCancelDuringVerificationKeepsVerifiedFilesAndRemovesTheRest() throws {
        let dests = makeDests(1)
        let engine = try makeEngine(dests: dests)
        var firstOK = true
        engine.onFileUpdate = { update in
            if update.status == .ok, firstOK { firstOK = false; engine.cancel() }
        }
        let result = engine.run()
        XCTAssertEqual(result.outcome, .cancelled)
        let files = TestSupport.allFiles(under: dests[0])
        XCTAssertTrue(files.allSatisfy { !$0.hasSuffix(OffloadEngine.partialSuffix) }, "nessun parziale: \(files)")
        let okCount = result.count(.ok, destination: 0)
        XCTAssertEqual(okCount, 1)
        var isDir: ObjCBool = false
        let regular = files.filter { FileManager.default.fileExists(atPath: dests[0].appendingPathComponent($0).path, isDirectory: &isDir) && !isDir.boolValue }
        XCTAssertEqual(regular.count, 1, "deve restare solo il file già verificato: \(files)")
    }

    func testResumeSkipsAlreadyVerifiedFilesAndFinishes() throws {
        let dests = makeDests(1)
        let journalDir = try TestSupport.makeTempDir("journal")
        defer { try? FileManager.default.removeItem(at: journalDir) }
        let store = JournalStore(directory: journalDir)

        let first = try makeEngine(dests: dests) { $0.journalStore = store }
        var firstOK = true
        first.onFileUpdate = { u in if u.status == .ok, firstOK { firstOK = false; first.cancel() } }
        let r1 = first.run()
        XCTAssertEqual(r1.outcome, .cancelled)

        let journal = try XCTUnwrap(store.latestResumable())
        XCTAssertEqual(journal.job.id, first.job.id)
        XCTAssertTrue(journal.isResumable)

        let second = try makeEngine(dests: dests, resume: journal) { $0.journalStore = store }
        let r2 = second.run()
        XCTAssertEqual(r2.outcome, .completed)
        XCTAssertTrue(r2.allOK)
        XCTAssertEqual(r2.skippedAlreadyVerified, 1)
        XCTAssertNil(store.latestResumable(), "a lavoro concluso non c'è più nulla da riprendere")
        for f in card.files {
            XCTAssertTrue(TestSupport.contentsEqual(card.root.appendingPathComponent(f.path), dests[0].appendingPathComponent(f.path)))
        }
    }

    func testSecondDestinationFailureDoesNotAffectFirstOne() throws {
        // La destinazione 2 punta a una cartella dove un FILE occupa il nome di una sottocartella: errore su quel file.
        let dests = makeDests(2)
        try FileManager.default.createDirectory(at: dests[1], withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dests[1].appendingPathComponent("CLIP"))   // «CLIP» è un file, non una cartella
        let result = try makeEngine(dests: dests).run()
        XCTAssertFalse(result.allOK)
        XCTAssertEqual(result.count(.ok, destination: 0), card.files.count)
        let clipFiles = result.files.filter { $0.relativePath.hasPrefix("CLIP/") }
        XCTAssertTrue(clipFiles.allSatisfy { $0.destinations[1].status == .error })
    }

    // MARK: Scanner

    func testScannerListsFilesAndSkipsSystemEntriesAndSymlinks() throws {
        try FileManager.default.createDirectory(at: card.root.appendingPathComponent(".Spotlight-V100"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: card.root.appendingPathComponent(".Spotlight-V100/store"))
        try Data("x".utf8).write(to: card.root.appendingPathComponent(".DS_Store"))
        try FileManager.default.createSymbolicLink(at: card.root.appendingPathComponent("link"), withDestinationURL: card.root.appendingPathComponent("tiny.txt"))
        let scan = try SourceScanner.scan(root: card.root)
        XCTAssertEqual(Set(scan.files.map(\.relativePath)), Set(card.files.map(\.path)))
        XCTAssertEqual(scan.totalSize, Int64(card.files.reduce(0) { $0 + $1.size }))
        XCTAssertEqual(scan.skipped.map(\.relativePath), ["link"])
    }
}
