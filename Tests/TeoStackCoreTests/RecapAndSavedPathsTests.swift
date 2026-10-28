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
    private func clip(_ id: Int64, offload: Int64, path: String, size: Int64, status: String = "ok", media: Bool = true, audio: Bool = false,
                      hash: String? = nil, dests: [String]? = nil, meta: [String: String] = [:]) -> ClipRecord {
        ClipRecord(id: id, offloadID: offload, binID: 1, relativePath: path, name: (path as NSString).lastPathComponent, size: size,
                   sourceHash: hash ?? "h\(id)", status: status, destinationStatuses: dests ?? [status], isMedia: media, metadata: meta,
                   offloadDate: Date(timeIntervalSince1970: 1_700_000_000), binName: "A001", dayName: "DAY01", isAudio: audio)
    }

    private func offload(_ id: Int64, _ outcome: String) -> OffloadRecord {
        OffloadRecord(id: id, jobID: UUID(), binID: 1, sourcePath: "/Volumes/CARD\(id)", destinations: ["/d"], startedAt: Date(),
                      finishedAt: Date(), outcome: outcome, allOK: outcome == "completed", totalBytes: 0)
    }

    private let prores: [String: String] = ["codec": "ProRes 4444", "resolution": "4448x3096", "frameRate": "24"]

    func testOverviewBackupsFormatsAndCameras() {
        let clips = [
            clip(1, offload: 1, path: "A001/A001C001.mov", size: 1000, dests: ["ok", "ok", "ok"],
                 meta: prores.merging(["durationSeconds": "60", "cameraIndex": "A", "reel": "A001"]) { $1 }),
            clip(2, offload: 1, path: "A001/A001C002.mov", size: 2000, dests: ["ok", "ok", "ok"],
                 meta: prores.merging(["durationSeconds": "30", "cameraIndex": "A", "reel": "A001"]) { $1 }),
            clip(3, offload: 1, path: "A001/clip.xml", size: 10, media: false, dests: ["ok", "ok", "ok"]),
            clip(4, offload: 2, path: "B001/B001C001.mxf", size: 5000, dests: ["ok"],
                 meta: ["codec": "XAVC", "resolution": "4096x2160", "cameraIndex": "B", "reel": "B001"]),
            clip(5, offload: 2, path: "S/T2.wav", size: 400, media: false, audio: true, dests: ["ok", "ok"],
                 meta: ["audioCodec": "PCM", "audioSampleRate": "48000", "audioBitDepth": "24", "audioChannels": "2", "durationSeconds": "20"]),
            clip(6, offload: 3, path: "C001/C001C001.mov", size: 700, status: "pending", dests: ["pending"]),                // offload annullato
            clip(7, offload: 4, path: "/Volumes/X/imp.mov", size: 900, status: "imported", dests: ["imported"],
                 meta: prores.merging(["durationSeconds": "10"]) { $1 }),                                                      // importato, mai verificato
        ]
        let recap = ProjectRecap.make(clips: clips, offloads: [offload(1, "completed"), offload(2, "completed"), offload(3, "cancelled"), offload(4, "imported")])

        // Clips Overview
        XCTAssertEqual(recap.video.clips, 5)
        XCTAssertEqual(recap.video.files, 5)
        XCTAssertEqual(recap.video.size, 1000 + 2000 + 5000 + 700 + 900)
        XCTAssertEqual(recap.video.durationSeconds, 100)
        XCTAssertEqual(recap.video.clipsWithDuration, 3)
        XCTAssertEqual(recap.video.clipsWithoutDuration, 2, "i clip senza durata non si stimano")
        XCTAssertEqual(recap.audio.clips, 1)
        XCTAssertEqual(recap.audio.durationSeconds, 20)
        XCTAssertEqual(recap.other.clips, 0, "gli altri file hanno file e peso, non clip")
        XCTAssertEqual(recap.other.files, 1)
        XCTAssertEqual(recap.other.size, 10)
        XCTAssertEqual(recap.total.clips, 6)
        XCTAssertEqual(recap.total.files, 7)
        XCTAssertEqual(recap.total.size, 1000 + 2000 + 10 + 5000 + 400 + 700 + 900)

        // Backups (Verified): clip per numero di copie verificate
        XCTAssertEqual(recap.backups.map(\.label), ["3+", "2", "1", "0"])
        XCTAssertEqual(recap.backups.map(\.clips), [2, 1, 1, 2], "3+: 2 clip · 2: audio · 1: MXF · 0: clip annullato + file importato")

        // formati e camere
        XCTAssertEqual(recap.videoFormats.count, 3, "ProRes MOV, XAVC MXF e il MOV senza metadata")
        let first = recap.videoFormats[0]
        XCTAssertEqual(first.codec, "ProRes 4444")
        XCTAssertEqual(first.fileType, "MOV")
        XCTAssertEqual(first.resolution, "4448x3096")
        XCTAssertEqual(first.fps, "24")
        XCTAssertEqual(first.group.clips, 3, "i due clip verificati + quello importato hanno lo stesso formato")
        XCTAssertTrue(recap.videoFormats.contains { $0.codec == nil && $0.resolution == nil && $0.fileType == "MOV" && $0.group.clips == 1 }, "senza metadata: codec e risoluzione assenti")
        XCTAssertEqual(recap.videoWithoutFormat, 1)
        XCTAssertEqual(recap.audioFormats.count, 1)
        XCTAssertEqual(recap.audioFormats[0].codec, "PCM")
        XCTAssertEqual(recap.audioFormats[0].sampleRate, "48000")
        XCTAssertEqual(recap.audioFormats[0].bitDepth, "24")

        XCTAssertEqual(recap.cameras.map { $0.camera }, [nil, "A", "B"], "nessuna camera nota → riga N/D (nil), poi A e B")
        let a = recap.cameras[1]
        XCTAssertEqual(a.group.clips, 2)
        XCTAssertEqual(a.reelCount, 1)
        XCTAssertEqual(a.frames, 60 * 24 + 30 * 24, "frame = durata × FPS, solo dove sono noti")
        XCTAssertNil(recap.cameras[2].frames, "il clip B non ha durata né FPS: frame non stimati")

        // schede e avvisi
        XCTAssertEqual(recap.cardCount, 2)
        XCTAssertEqual(recap.incompleteOffloads, 1)
        XCTAssertEqual(recap.importedFiles, 1)
        XCTAssertEqual(recap.problemFiles, 1)
        XCTAssertEqual(recap.verifiedBytes, 1000 + 2000 + 10 + 5000 + 400)
        XCTAssertFalse(recap.isEmpty)
    }

    func testSameCardOffloadedTwiceInTheSameBinCountsOnce() {
        let clips = [
            clip(1, offload: 1, path: "A001/C1.mov", size: 1000, hash: "same", meta: prores),
            clip(2, offload: 2, path: "A001/C1.mov", size: 1000, hash: "same", meta: prores),    // secondo offload della stessa scheda
        ]
        let recap = ProjectRecap.make(clips: clips, offloads: [offload(1, "completed"), offload(2, "completed")])
        XCTAssertEqual(recap.video.clips, 1)
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
        XCTAssertEqual(recap.video.clips, 2)
        XCTAssertEqual(recap.verifiedBytes, 2000)
        XCTAssertEqual(recap.cardCount, 2)
    }

    func testDuplicateWithProblemsIsReplacedByTheVerifiedCopy() {
        let clips = [
            clip(1, offload: 1, path: "A001/C1.mov", size: 1000, status: "mismatch", hash: "same"),
            clip(2, offload: 2, path: "A001/C1.mov", size: 1000, status: "ok", hash: "same"),
        ]
        let recap = ProjectRecap.make(clips: clips, offloads: [offload(1, "completed"), offload(2, "completed")])
        XCTAssertEqual(recap.total.files, 1)
        XCTAssertEqual(recap.problemFiles, 0)
        XCTAssertEqual(recap.verifiedBytes, 1000)
    }

    func testEmptyRecap() {
        XCTAssertTrue(ProjectRecap.make(clips: [], offloads: []).isEmpty)
        XCTAssertTrue(ProjectRecap.make(clips: [], offloads: [offload(1, "imported")]).isEmpty, "un'importazione senza file non è niente da mostrare")
        let recap = ProjectRecap.make(clips: [], offloads: [offload(1, "cancelled")])
        XCTAssertFalse(recap.isEmpty, "c'è un offload non completato da segnalare")
        XCTAssertEqual(recap.incompleteOffloads, 1)
        XCTAssertEqual(recap.cardCount, 0)
        XCTAssertEqual(recap.backups.map(\.clips), [0, 0, 0, 0])
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
            XCTAssertEqual(recap.total.files, card.files.count)
            XCTAssertEqual(recap.video.clips, 4, ".mov ×2, .ari e .MXF sono clip; XML, bin e txt no")
            XCTAssertEqual(recap.other.files, card.files.count - 4)
            XCTAssertEqual(recap.verifiedBytes, total)
            XCTAssertEqual(recap.total.size, total)
            XCTAssertEqual(recap.video.clipsWithDuration, 0, "metadata non ancora letti: nessuna durata inventata")
            XCTAssertEqual(recap.video.durationSeconds, 0)
            XCTAssertEqual(recap.videoWithoutFormat, 4)
            XCTAssertEqual(recap.backups.map(\.clips), [0, 0, 4, 0], "una sola destinazione: tutti i clip hanno 1 copia verificata")
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
