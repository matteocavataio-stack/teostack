import XCTest
@testable import TeoStackCore

final class SavedPathsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var dir: URL!

    override func setUpWithError() throws {
        defaults = UserDefaults(suiteName: "teostack.savedpaths.\(UUID().uuidString)")!
        dir = try TestSupport.makeTempDir("saved")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    func testAddRemoveAndNoDuplicates() {
        let store = SavedPathsStore(defaults: defaults)
        XCTAssertEqual(store.paths, [])
        XCTAssertTrue(store.add("/Volumes/BACKUP_A"))
        XCTAssertTrue(store.add("/Volumes/BACKUP_B"))
        XCTAssertFalse(store.add("/Volumes/BACKUP_A"), "stesso percorso: non si duplica")
        XCTAssertFalse(store.add("/Volumes/BACKUP_A/"), "barra finale: stesso percorso")
        XCTAssertFalse(store.add("/Volumes/X/../BACKUP_A"), "percorso con «..»: stesso percorso")
        XCTAssertFalse(store.add(""))
        XCTAssertEqual(store.paths, ["/Volumes/BACKUP_A", "/Volumes/BACKUP_B"], "l'ordine di aggiunta si conserva")
        XCTAssertTrue(store.contains("/Volumes/BACKUP_B/"))

        store.remove("/Volumes/BACKUP_A/")
        XCTAssertEqual(store.paths, ["/Volumes/BACKUP_B"])
        store.remove("/Volumes/NON_SALVATO")
        XCTAssertEqual(store.paths, ["/Volumes/BACKUP_B"])
    }

    func testPathsSurviveANewInstanceAndAvailabilityDetectsUnplugged() throws {
        SavedPathsStore(defaults: defaults).add(dir.path)
        XCTAssertEqual(SavedPathsStore(defaults: defaults).paths, [dir.path], "i percorsi restano tra un avvio e l'altro")

        XCTAssertTrue(SavedPathsStore.isAvailable(dir.path))
        XCTAssertFalse(SavedPathsStore.isAvailable(dir.appendingPathComponent("disco_scollegato").path))
        let file = dir.appendingPathComponent("file.txt")
        try Data("x".utf8).write(to: file)
        XCTAssertFalse(SavedPathsStore.isAvailable(file.path), "un file non è una cartella di destinazione")
    }
}

final class RecapTests: XCTestCase {
    private func clip(_ id: Int64, offload: Int64, path: String, size: Int64, status: String = "ok", media: Bool = true,
                      hash: String? = nil, meta: [String: String] = [:]) -> ClipRecord {
        ClipRecord(id: id, offloadID: offload, binID: 1, relativePath: path, name: (path as NSString).lastPathComponent, size: size,
                   sourceHash: hash ?? "h\(id)", status: status, destinationStatuses: [status], isMedia: media, metadata: meta,
                   offloadDate: Date(timeIntervalSince1970: 1_700_000_000), binName: "A001", dayName: "DAY01")
    }

    private func offload(_ id: Int64, _ outcome: String) -> OffloadRecord {
        OffloadRecord(id: id, jobID: UUID(), binID: 1, sourcePath: "/Volumes/CARD\(id)", destinations: ["/d"], startedAt: Date(),
                      finishedAt: Date(), outcome: outcome, allOK: outcome == "completed", totalBytes: 0)
    }

    private let prores = ["codec": "ProRes 4444", "resolution": "4448x3096"]

    func testRecapTotalsFormatsAndHonestUnknowns() {
        let clips = [
            clip(1, offload: 1, path: "A001/A001C001.mov", size: 1000, meta: prores.merging(["durationSeconds": "60"]) { $1 }),
            clip(2, offload: 1, path: "A001/A001C002.mov", size: 2000, meta: prores.merging(["durationSeconds": "30"]) { $1 }),
            clip(3, offload: 1, path: "A001/clip.xml", size: 10, media: false),
            clip(4, offload: 2, path: "B001/B001C001.mxf", size: 5000, meta: ["codec": "XAVC", "resolution": "4096x2160"]),
            clip(5, offload: 3, path: "C001/C001C001.mov", size: 700, status: "pending"),
        ]
        let recap = ProjectRecap.make(clips: clips, offloads: [offload(1, "completed"), offload(2, "completed"), offload(3, "cancelled")])

        XCTAssertEqual(recap.verifiedBytes, 8010, "conta solo i file verificati OK")
        XCTAssertEqual(recap.notVerifiedFiles, 1)
        XCTAssertEqual(recap.fileCount, 5)
        XCTAssertEqual(recap.clipCount, 4, "il file XML non è un clip")
        XCTAssertEqual(recap.cardCount, 2, "l'offload annullato non è una scheda scaricata")
        XCTAssertEqual(recap.incompleteOffloads, 1)
        XCTAssertEqual(recap.durationSeconds, 90)
        XCTAssertEqual(recap.clipsWithDuration, 2)
        XCTAssertEqual(recap.clipsWithoutDuration, 2, "i clip senza durata non vengono stimati")
        XCTAssertEqual(recap.clipsWithoutFormat, 1)
        XCTAssertEqual(recap.formats.map(\.label), ["ProRes 4444 · 4448x3096 · .MOV", ".MOV", "XAVC · 4096x2160 · .MXF"])
        XCTAssertEqual(recap.formats.map(\.clips), [2, 1, 1])
        XCTAssertEqual(recap.formats[0].bytes, 3000)
        XCTAssertFalse(recap.isEmpty)
    }

    func testSameCardOffloadedTwiceInTheSameBinCountsOnce() {
        let clips = [
            clip(1, offload: 1, path: "A001/C1.mov", size: 1000, hash: "same", meta: prores),
            clip(2, offload: 2, path: "A001/C1.mov", size: 1000, hash: "same", meta: prores),    // secondo offload della stessa scheda
        ]
        let recap = ProjectRecap.make(clips: clips, offloads: [offload(1, "completed"), offload(2, "completed")])
        XCTAssertEqual(recap.clipCount, 1)
        XCTAssertEqual(recap.verifiedBytes, 1000)
        XCTAssertEqual(recap.cardCount, 1, "la stessa scheda ripetuta non conta due volte")
    }

    func testSamePathWithDifferentContentCountsTwice() {
        // scheda riformattata e riusata: stesso percorso, contenuto diverso → sono due file veri
        let clips = [
            clip(1, offload: 1, path: "A001/C1.mov", size: 1000, hash: "one", meta: prores),
            clip(2, offload: 2, path: "A001/C1.mov", size: 1000, hash: "two", meta: prores),
        ]
        let recap = ProjectRecap.make(clips: clips, offloads: [offload(1, "completed"), offload(2, "completed")])
        XCTAssertEqual(recap.clipCount, 2)
        XCTAssertEqual(recap.verifiedBytes, 2000)
        XCTAssertEqual(recap.cardCount, 2)
    }

    func testDuplicateWithProblemsIsReplacedByTheVerifiedCopy() {
        let clips = [
            clip(1, offload: 1, path: "A001/C1.mov", size: 1000, status: "mismatch", hash: "same"),
            clip(2, offload: 2, path: "A001/C1.mov", size: 1000, status: "ok", hash: "same"),
        ]
        let recap = ProjectRecap.make(clips: clips, offloads: [offload(1, "completed"), offload(2, "completed")])
        XCTAssertEqual(recap.fileCount, 1)
        XCTAssertEqual(recap.notVerifiedFiles, 0)
        XCTAssertEqual(recap.verifiedBytes, 1000)
    }

    func testEmptyRecap() {
        XCTAssertTrue(ProjectRecap.make(clips: [], offloads: []).isEmpty)
        let recap = ProjectRecap.make(clips: [], offloads: [offload(1, "cancelled")])
        XCTAssertFalse(recap.isEmpty, "c'è un offload non completato da segnalare")
        XCTAssertEqual(recap.incompleteOffloads, 1)
        XCTAssertEqual(recap.cardCount, 0)
    }

    func testRecapOfFolderAndLibraryFromARealOffload() throws {
        let store = try ProjectStore(path: nil)
        let card = try FakeCard.create()
        let dest = try TestSupport.makeTempDir("recapdest")
        defer {
            try? FileManager.default.removeItem(at: card.root.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: dest)
        }
        let p = try store.createProject(name: "Film")
        let day = try store.createDay(projectID: p.id, name: "DAY01")
        let bin = try store.createBin(parentID: day.id, name: "A001_CARD")
        let library = try store.tree(projectID: p.id)

        XCTAssertTrue(try store.recap(underNode: library.id).isEmpty)

        let root = dest.appendingPathComponent("A001_CARD", isDirectory: true)
        let job = OffloadJob(sourceURL: card.root, destinationRoots: [root], destinationBases: [dest])
        try store.beginOffload(jobID: job.id, binID: bin.id, sourcePath: card.root.path, destinations: [root.path])
        let result = OffloadEngine(job: job, scan: try SourceScanner.scan(root: card.root)).run()
        try store.finishOffload(result)
        XCTAssertTrue(result.allOK)

        let total = Int64(card.files.reduce(0) { $0 + $1.size })
        for nodeID in [library.id, day.id, bin.id] {
            let recap = try store.recap(underNode: nodeID)
            XCTAssertEqual(recap.cardCount, 1)
            XCTAssertEqual(recap.fileCount, card.files.count)
            XCTAssertEqual(recap.clipCount, 4, ".mov ×2, .ari e .MXF sono clip; XML, bin e txt no")
            XCTAssertEqual(recap.verifiedBytes, total)
            XCTAssertEqual(recap.clipsWithDuration, 0, "metadata non ancora letti: nessuna durata inventata")
            XCTAssertEqual(recap.durationSeconds, 0)
            XCTAssertEqual(recap.clipsWithoutFormat, 4)
        }
    }

    func testHistoryFollowsTheLanguageButOldEntriesKeepTheirText() throws {
        defer { Loc.language = .italian }
        let store = try ProjectStore(path: nil)
        let card = try FakeCard.create()
        let dest = try TestSupport.makeTempDir("histdest")
        defer {
            try? FileManager.default.removeItem(at: card.root.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: dest)
        }
        let p = try store.createProject(name: "Film")
        let bin = try store.createBin(parentID: try store.createDay(projectID: p.id, name: "DAY01").id, name: "a001")
        let root = dest.appendingPathComponent("out", isDirectory: true)
        let job = OffloadJob(sourceURL: card.root, destinationRoots: [root], destinationBases: [dest])
        try store.beginOffload(jobID: job.id, binID: bin.id, sourcePath: card.root.path, destinations: [root.path])
        try store.finishOffload(OffloadEngine(job: job, scan: try SourceScanner.scan(root: card.root)).run())
        // voce «vecchia» (senza testi traducibili), come quelle registrate prima di questa versione
        try store.logEvent(projectID: p.id, kind: "offloadCompleted", title: "Offload completato nel bin «vecchio»: 1 file, 1.00 KB, tutti OK")

        Loc.language = .italian
        var events = try store.history(projectID: p.id)
        XCTAssertEqual(events.count, 2)
        let current = try XCTUnwrap(events.first { $0.title.contains("a001") })
        XCTAssertTrue(current.title.hasPrefix("Offload completato nel bin «a001»: \(card.files.count) file, "), current.title)

        Loc.language = .english
        events = try store.history(projectID: p.id)
        let english = try XCTUnwrap(events.first { $0.title.contains("a001") })
        XCTAssertTrue(english.title.hasPrefix("Offload completed in bin “a001”: \(card.files.count) files, "), english.title)
        XCTAssertTrue(english.title.hasSuffix("all OK"), english.title)
        XCTAssertTrue(english.detail?.contains("identical to the source on 1 destination(s)") == true, english.detail ?? "")

        Loc.language = .spanish
        XCTAssertTrue(try XCTUnwrap(store.history(projectID: p.id).first { $0.title.contains("a001") }).title.hasPrefix("Offload completado en el bin «a001»"))
        Loc.language = .catalan
        XCTAssertTrue(try XCTUnwrap(store.history(projectID: p.id).first { $0.title.contains("a001") }).title.hasPrefix("Offload completat al bin «a001»"))

        let old = try XCTUnwrap(try store.history(projectID: p.id).first { $0.title.contains("vecchio") })
        XCTAssertEqual(old.title, "Offload completato nel bin «vecchio»: 1 file, 1.00 KB, tutti OK", "le voci vecchie restano come erano")
    }
}
