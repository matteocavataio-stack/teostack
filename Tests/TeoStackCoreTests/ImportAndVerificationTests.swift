import XCTest
@testable import TeoStackCore

/// «Importa media»: file già presenti su disco registrati in un bin senza copiarli, e pallino verde/rosso dei bin.
final class ImportMediaTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = try TestSupport.makeTempDir("import")
        let fm = FileManager.default
        for dir in ["CardA/V/sub", "Loose"] { try fm.createDirectory(at: base.appendingPathComponent(dir), withIntermediateDirectories: true) }
        for (i, name) in ["CardA/V/C001.mov", "CardA/V/sub/C002.mxf", "CardA/S01.wav", "CardA/notes.txt", "CardA/.DS_Store",
                          "Loose/one.mov", "Loose/two.mpg"].enumerated() {
            try TestSupport.writeRandomFile(base.appendingPathComponent(name), size: 3_000 + i, seed: UInt64(i + 20))
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
    }

    private func bin(_ store: ProjectStore) throws -> (Project, TreeNode) {
        let p = try store.createProject(name: "Film")
        return (p, try store.createBin(parentID: try store.tree(projectID: p.id).id, name: "Importati"))
    }

    func testFoldersAreScannedAndLooseFilesAreGroupedByTheirFolder() throws {
        let groups = try SourceScanner.importGroups(for: [
            base.appendingPathComponent("CardA"),
            base.appendingPathComponent("Loose/one.mov"),
            base.appendingPathComponent("Loose/two.mpg"),
            base.appendingPathComponent("Loose/one.mov"),                      // scelto due volte: una sola
        ])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].root.lastPathComponent, "CardA")
        XCTAssertEqual(groups[0].files.map(\.relativePath).sorted(), ["S01.wav", "V/C001.mov", "V/sub/C002.mxf", "notes.txt"], ".DS_Store escluso")
        XCTAssertEqual(groups[1].root.lastPathComponent, "Loose", "i file singoli si raggruppano per cartella")
        XCTAssertEqual(groups[1].files.map(\.relativePath).sorted(), ["one.mov", "two.mpg"])
        XCTAssertThrowsError(try SourceScanner.importGroups(for: [base.appendingPathComponent("non_esiste")]))
    }

    func testImportedBinsAreNamedLikeTheFileOrFolder() throws {
        let bins = try SourceScanner.importBins(for: [
            base.appendingPathComponent("CardA"),
            base.appendingPathComponent("Loose/one.mov"),
            base.appendingPathComponent("Loose/two.mpg"),
            base.appendingPathComponent("Loose/one.mov"),                      // scelto due volte: un solo bin
            base.appendingPathComponent("CardA/S01.wav"),                      // dentro una cartella già scelta: nessun bin in più
        ])
        XCTAssertEqual(bins.map(\.name), ["CardA", "one.mov", "two.mpg"], "il bin di un file ha lo stesso nome del file")
        XCTAssertEqual(bins[1].files.map(\.relativePath), ["one.mov"])
        XCTAssertEqual(bins[1].root.lastPathComponent, "Loose")
        XCTAssertEqual(bins[0].files.count, 4)
        XCTAssertThrowsError(try SourceScanner.importBins(for: [base.appendingPathComponent("non_esiste")]))

        // importandoli davvero: il bin ha il nome del file e riusarlo non crea doppioni
        let store = try ProjectStore(path: nil)
        let p = try store.createProject(name: "Film")
        let library = try store.tree(projectID: p.id)
        for b in bins.dropFirst() {
            let node = try store.findOrCreateBin(parentID: library.id, name: b.name).node
            XCTAssertEqual(node.name, b.name)
            XCTAssertEqual(try store.importFiles(binID: node.id, rootPath: b.root.path, files: b.files).added, 1)
        }
    }

    func testImportedClipsAreNeverMarkedVerifiedAndSourceFilesAreUntouched() throws {
        let store = try ProjectStore(path: nil)
        let (p, bin) = try bin(store)
        let before = try TestSupport.snapshot(of: base)
        let group = try XCTUnwrap(try SourceScanner.importGroups(for: [base.appendingPathComponent("CardA")]).first)

        let result = try store.importFiles(binID: bin.id, rootPath: group.root.path, files: group.files)
        XCTAssertEqual(result.added, 4)
        XCTAssertEqual(result.alreadyPresent, 0)

        let clips = try store.clips(underNode: bin.id, mediaOnly: false)
        XCTAssertEqual(clips.count, 4)
        for c in clips {
            XCTAssertEqual(c.status, "imported", "importare non è verificare: mai «ok»")
            XCTAssertEqual(c.destinationStatuses, ["imported"])
            XCTAssertNil(c.sourceHash, "nessun hash inventato")
            XCTAssertTrue(c.hasLocalFile)
        }
        XCTAssertEqual(clips.filter(\.isMedia).map(\.name).sorted(), ["C001.mov", "C002.mxf"])
        XCTAssertEqual(clips.filter(\.isAudio).map(\.name), ["S01.wav"])
        XCTAssertEqual(try store.projects().first { $0.id == p.id }?.clipCount, 2, "i clip importati contano nel progetto")
        XCTAssertEqual(try TestSupport.snapshot(of: base), before, "i file importati non vengono toccati")

        // dove stanno: il percorso della cartella importata (letti da lì, non copiati)
        let offload = try XCTUnwrap(try store.offloads(binID: bin.id).first)
        XCTAssertEqual(offload.outcome, "imported")
        XCTAssertEqual(try store.destinationRoots(offloadID: offload.id), [group.root.path])

        // nuovo importo della stessa cartella: nessun doppione; un file nuovo si aggiunge
        try TestSupport.writeRandomFile(base.appendingPathComponent("CardA/V/C003.mov"), size: 1_000, seed: 99)
        let again = try XCTUnwrap(try SourceScanner.importGroups(for: [base.appendingPathComponent("CardA")]).first)
        let second = try store.importFiles(binID: bin.id, rootPath: again.root.path, files: again.files)
        XCTAssertEqual(second.added, 1)
        XCTAssertEqual(second.alreadyPresent, 4)
        XCTAssertEqual(second.jobID, result.jobID, "stessa importazione, non una nuova")
        XCTAssertEqual(try store.clips(underNode: bin.id, mediaOnly: false).count, 5)
        XCTAssertEqual(try store.offloads(binID: bin.id).count, 1)

        // il riepilogo li dichiara non verificati
        let recap = try store.recap(underNode: bin.id)
        XCTAssertEqual(recap.importedFiles, 5)
        XCTAssertEqual(recap.verifiedBytes, 0)
        XCTAssertEqual(recap.backups.map(\.clips), [0, 0, 0, 4], "3 video + 1 audio, tutti con 0 copie verificate")
        XCTAssertEqual(recap.cardCount, 0, "un'importazione non è una scheda scaricata")
    }

    func testImportOnlyIntoABin() throws {
        let store = try ProjectStore(path: nil)
        let p = try store.createProject(name: "Film")
        let library = try store.tree(projectID: p.id)
        let file = try SourceFile(relativePath: "a.mov", size: 1, modificationDate: Date(), creationDate: nil)
        XCTAssertThrowsError(try store.importFiles(binID: library.id, rootPath: "/x", files: [file]))
        XCTAssertThrowsError(try store.importFiles(binID: 9999, rootPath: "/x", files: [file]))
    }

    func testMetadataOfImportedFilesIsReadFromWhereTheyAre() throws {
        guard let probe = FFprobeRunner.locate(), let ffmpeg = FFmpegRunner.locate()?.executable else { throw XCTSkip("ffprobe/ffmpeg non installati") }
        let wav = base.appendingPathComponent("Loose/take.wav")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=1", "-c:a", "pcm_s24le", wav.path]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)

        let store = try ProjectStore(path: nil)
        let (_, bin) = try bin(store)
        let group = try XCTUnwrap(try SourceScanner.importGroups(for: [wav]).first)
        let result = try store.importFiles(binID: bin.id, rootPath: group.root.path, files: group.files)
        // dopo l'importazione l'app legge da sola i metadata dei clip di quell'importazione (video e audio)
        let clips = try store.clips(forJobID: result.jobID)
        XCTAssertEqual(clips.map(\.name), ["take.wav"])
        let summary = try MetadataImporter.importMetadata(for: clips, store: store, runner: nil, probe: probe)
        XCTAssertEqual(summary.read, 1, summary.text)
        let read = try XCTUnwrap(try store.clips(underNode: bin.id, mediaOnly: true).first { $0.name == "take.wav" })
        XCTAssertEqual(read.metadata["audioSampleRate"], "48000")
        XCTAssertEqual(read.metadata["audioBitDepth"], "24")
        XCTAssertEqual(read.status, "imported", "leggere i metadata non cambia lo stato")
    }
}

final class BinVerificationTests: XCTestCase {
    private var card: FakeCard!
    private var dest: URL!
    private var store: ProjectStore!

    override func setUpWithError() throws {
        card = try FakeCard.create()
        dest = try TestSupport.makeTempDir("verdest")
        store = try ProjectStore(path: nil)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: card.root.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: dest)
    }

    private func verification(of bin: TreeNode, project: Project) throws -> BinVerification? {
        func find(_ n: TreeNode) -> TreeNode? {
            if n.id == bin.id { return n }
            for c in n.children ?? [] { if let f = find(c) { return f } }
            return nil
        }
        return find(try store.tree(projectID: project.id))?.verification
    }

    private func start(_ bin: TreeNode, to name: String) throws -> (OffloadJob, OffloadEngine) {
        let root = dest.appendingPathComponent(name, isDirectory: true)
        let job = OffloadJob(sourceURL: card.root, destinationRoots: [root], destinationBases: [dest])
        try store.beginOffload(jobID: job.id, binID: bin.id, sourcePath: card.root.path, destinations: [root.path])
        return (job, OffloadEngine(job: job, scan: try SourceScanner.scan(root: card.root)))
    }

    func testGreenWhenEverythingIsVerified() throws {
        let p = try store.createProject(name: "Film")
        let bin = try store.createBin(parentID: try store.tree(projectID: p.id).id, name: "a001")
        XCTAssertNil(try verification(of: bin, project: p), "bin vuoto: nessun pallino")

        let (job, engine) = try start(bin, to: "out")
        XCTAssertEqual(try verification(of: bin, project: p), .inProgress, "offload in corso")
        let result = engine.run()
        try store.finishOffload(result)
        XCTAssertTrue(result.allOK)
        XCTAssertEqual(try verification(of: bin, project: p), .verified)
        _ = job
    }

    func testRedWhenAFileIsNotVerified() throws {
        let p = try store.createProject(name: "Film")
        let bin = try store.createBin(parentID: try store.tree(projectID: p.id).id, name: "a001")
        let (_, engine) = try start(bin, to: "out")
        let target = dest.appendingPathComponent("out/CLIP/C0001.MXF" + OffloadEngine.partialSuffix).path
        engine.onCopied("CLIP/C0001.MXF") {
            let fd = open(target, O_RDWR)
            var b: UInt8 = 0; _ = pread(fd, &b, 1, 5); b ^= 1; _ = pwrite(fd, &b, 1, 5); close(fd)
        }
        let result = engine.run()
        try store.finishOffload(result)
        XCTAssertFalse(result.allOK)
        XCTAssertEqual(try verification(of: bin, project: p), .notVerified)
    }

    func testRedForCancelledOffloadButGreenAfterItIsRedoneAndVerified() throws {
        let p = try store.createProject(name: "Film")
        let bin = try store.createBin(parentID: try store.tree(projectID: p.id).id, name: "a001")
        let (_, first) = try start(bin, to: "out")
        first.onFileUpdate = { if $0.status == .copied { first.cancel() } }
        try store.finishOffload(first.run())
        XCTAssertEqual(try verification(of: bin, project: p), .notVerified, "annullato: non verificato")

        let (_, second) = try start(bin, to: "out2")                  // si rifà da capo in un'altra destinazione
        let result = second.run()
        try store.finishOffload(result)
        XCTAssertTrue(result.allOK)
        XCTAssertEqual(try verification(of: bin, project: p), .verified, "il vecchio offload annullato non tiene rosso un bin ormai verificato")
    }

    func testImportedBinIsNotVerified() throws {
        let p = try store.createProject(name: "Film")
        let bin = try store.createBin(parentID: try store.tree(projectID: p.id).id, name: "importati")
        let group = try XCTUnwrap(try SourceScanner.importGroups(for: [card.root]).first)
        try store.importFiles(binID: bin.id, rootPath: group.root.path, files: group.files)
        XCTAssertEqual(try verification(of: bin, project: p), .notVerified, "file importati senza copia verificata")
    }
}
