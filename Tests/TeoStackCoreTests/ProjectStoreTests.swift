import XCTest
@testable import TeoStackCore

final class ProjectStoreTests: XCTestCase {
    var store: ProjectStore!

    override func setUpWithError() throws {
        store = try ProjectStore(path: nil)
    }

    // MARK: Nomi

    func testNameValidation() throws {
        XCTAssertEqual(try NameValidator.validated("  DAY01_20261016 "), "DAY01_20261016")
        for bad in ["", "   ", "a/b", "a:b", "a*b", "a?b", "a\"b", "a<b", "a|b", "a\\b", ".nascosto", "fine.", String(repeating: "x", count: 101)] {
            XCTAssertThrowsError(try NameValidator.validated(bad), "«\(bad)» doveva essere rifiutato")
        }
        XCTAssertEqual(try NameValidator.validated("A_0001_1DET"), "A_0001_1DET")
    }

    func testDayNameSuggestion() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 12))!
        XCTAssertEqual(NameSuggestions.dayName(existingDayCount: 0, date: date, calendar: cal), "DAY01_20261016")
        XCTAssertEqual(NameSuggestions.dayName(existingDayCount: 11, date: date, calendar: cal), "DAY12_20261016")
    }

    // MARK: Progetti e albero

    func testProjectLifecycle() throws {
        let p = try store.createProject(name: "Film Uno", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertThrowsError(try store.createProject(name: "film uno")) { error in
            guard case ProjectStoreError.duplicateName = error else { return XCTFail("\(error)") }
        }
        var list = try store.projects()
        XCTAssertEqual(list.map(\.name), ["Film Uno"])
        XCTAssertEqual(list[0].clipCount, 0)
        XCTAssertEqual(list[0].createdAt.timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)

        try store.renameProject(id: p.id, to: "Film Due")
        list = try store.projects()
        XCTAssertEqual(list.map(\.name), ["Film Due"])
        let other = try store.createProject(name: "Altro")
        XCTAssertThrowsError(try store.renameProject(id: other.id, to: "FILM DUE"))

        try store.deleteProject(id: p.id)
        XCTAssertEqual(try store.projects().map(\.name), ["Altro"])
    }

    func testTreeStructureRulesAndUniqueness() throws {
        let p = try store.createProject(name: "P")
        let lib = try store.tree(projectID: p.id)
        XCTAssertEqual(lib.kind, .library)
        XCTAssertEqual(lib.name, "Library")
        XCTAssertEqual(lib.children, [])

        let day = try store.createDay(projectID: p.id, name: "DAY01_20261016")
        let bin = try store.createBin(parentID: day.id, name: "A_0001_1DET")
        XCTAssertThrowsError(try store.createDay(projectID: p.id, name: "day01_20261016")) // nomi uguali senza distinzione maiuscole
        XCTAssertThrowsError(try store.createBin(parentID: day.id, name: "a_0001_1det"))
        XCTAssertThrowsError(try store.createBin(parentID: bin.id, name: "BinInBin"))      // dentro un bin non si crea nulla
        XCTAssertThrowsError(try store.createFolder(parentID: bin.id, name: "FolderInBin"))
        XCTAssertThrowsError(try store.createDay(projectID: p.id, name: "con/barra"))
        XCTAssertThrowsError(try store.createDay(projectID: p.id, name: "con/barra"))
        // un nome uguale in un altro giorno è permesso
        let day2 = try store.createDay(projectID: p.id, name: "DAY02_20261017")
        XCTAssertNoThrow(try store.createBin(parentID: day2.id, name: "A_0001_1DET"))

        let tree = try store.tree(projectID: p.id)
        XCTAssertEqual(tree.children?.map(\.name), ["DAY01_20261016", "DAY02_20261017"])
        XCTAssertEqual(tree.children?[0].children?.map(\.name), ["A_0001_1DET"])
        XCTAssertNil(tree.children?[0].children?[0].children)
        XCTAssertEqual(bin.kind, .bin)
    }

    func testRenameAndDeleteRules() throws {
        let p = try store.createProject(name: "P")
        let lib = try store.tree(projectID: p.id)
        let day = try store.createDay(projectID: p.id, name: "D1")
        let day2 = try store.createDay(projectID: p.id, name: "D2")
        let bin = try store.createBin(parentID: day.id, name: "B1")
        _ = try store.createBin(parentID: day.id, name: "B2")

        XCTAssertThrowsError(try store.renameNode(id: lib.id, to: "X"))
        XCTAssertThrowsError(try store.deleteNode(id: lib.id))
        XCTAssertThrowsError(try store.renameNode(id: bin.id, to: "b2"))
        try store.renameNode(id: bin.id, to: "B1bis")
        try store.renameNode(id: bin.id, to: "B1bis")          // stesso nome su se stesso: nessun errore
        XCTAssertEqual(try store.tree(projectID: p.id).children?[0].children?.map(\.name), ["B1bis", "B2"])

        XCTAssertEqual(try store.deletionImpact(nodeID: day.id), .init(bins: 2, offloads: 0, clips: 0))
        try store.deleteNode(id: day.id)
        XCTAssertEqual(try store.tree(projectID: p.id).children?.map(\.name), ["D2"])
        XCTAssertNotNil(day2)
    }

    func testDeletingOneBinKeepsSiblingsDaysAndOtherProjects() throws {
        let card = try FakeCard.create()
        let destBase = try TestSupport.makeTempDir("dest")
        defer {
            try? FileManager.default.removeItem(at: card.root.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: destBase)
        }
        let p = try store.createProject(name: "Film")
        let other = try store.createProject(name: "Altro")
        let day1 = try store.createDay(projectID: p.id, name: "D1")
        let day2 = try store.createDay(projectID: p.id, name: "D2")
        let binA = try store.createBin(parentID: day1.id, name: "A")
        let binB = try store.createBin(parentID: day1.id, name: "B")
        let binC = try store.createBin(parentID: day2.id, name: "C")
        for (i, bin) in [binA, binB, binC].enumerated() {
            let r = try runRealOffload(binID: bin.id, dests: [destBase.appendingPathComponent("out\(i)")], card: card)
            XCTAssertTrue(r.allOK)
        }
        XCTAssertEqual(try store.projects().first { $0.id == p.id }?.clipCount, 12)

        try store.deleteNode(id: binA.id)        // solo il bin selezionato

        let tree = try store.tree(projectID: p.id)
        XCTAssertEqual(tree.children?.map(\.name), ["D1", "D2"])
        XCTAssertEqual(tree.children?[0].children?.map(\.name), ["B"])
        XCTAssertEqual(tree.children?[1].children?.map(\.name), ["C"])
        XCTAssertEqual(try store.clips(underNode: binB.id).count, 4)
        XCTAssertEqual(try store.clips(underNode: binC.id).count, 4)
        XCTAssertEqual(try store.projects().first { $0.id == p.id }?.clipCount, 8)
        XCTAssertNotNil(other)

        try store.deleteNode(id: day1.id)        // solo il giorno selezionato (con i suoi bin)
        XCTAssertEqual(try store.tree(projectID: p.id).children?.map(\.name), ["D2"])
        XCTAssertEqual(try store.clips(underNode: binC.id).count, 4)
        XCTAssertEqual(try store.projects().map(\.name).sorted(), ["Altro", "Film"], "il progetto resta")
    }

    func testDeletingNodesNeverTouchesTheDisk() throws {
        let dir = try TestSupport.makeTempDir("disk")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("P/D1/B1/clip.mov")
        try TestSupport.writeRandomFile(file, size: 1000, seed: 1)
        let p = try store.createProject(name: "P")
        let day = try store.createDay(projectID: p.id, name: "D1")
        _ = try store.createBin(parentID: day.id, name: "B1")
        try store.deleteNode(id: day.id)
        try store.deleteProject(id: p.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testFoldersAndBinsAtAnyLevelAreOptional() throws {
        let p = try store.createProject(name: "Film")
        let lib = try store.tree(projectID: p.id)
        // un bin può stare direttamente nella Library, senza giorno né cartelle
        let direct = try store.createBin(parentID: lib.id, name: "A001")
        XCTAssertEqual(try store.binTarget(binID: direct.id)?.folderPath, [])
        XCTAssertEqual(try store.binTarget(binID: direct.id)?.displayPath, "Film › A001")
        // oppure in giorno + sottocartelle annidate
        let day = try store.createDay(projectID: p.id, name: "DAY01_20261016")
        let cam = try store.createFolder(parentID: day.id, name: "CAM_A")
        let sub = try store.createFolder(parentID: cam.id, name: "Mattina")
        XCTAssertThrowsError(try store.createDay(projectID: p.id, name: "day01_20261016"))
        XCTAssertThrowsError(try store.createFolder(parentID: cam.id, name: "mattina"), "nomi uguali senza distinzione di maiuscole")
        let deep = try store.createBin(parentID: sub.id, name: "B002")
        XCTAssertEqual(try store.binTarget(binID: deep.id)?.folderPath, ["DAY01_20261016", "CAM_A", "Mattina"])
        XCTAssertEqual(try store.binTarget(binID: deep.id)?.displayPath, "Film › DAY01_20261016 › CAM_A › Mattina › B002")
        // il conteggio dei clip dell'albero e la cancellazione di una cartella includono i bin annidati
        XCTAssertEqual(try store.deletionImpact(nodeID: cam.id).bins, 1)
        try store.deleteNode(id: cam.id)
        XCTAssertNil(try store.binTarget(binID: deep.id))
        XCTAssertNotNil(try store.binTarget(binID: direct.id), "il resto resta")
    }

    func testFindOrCreateBinReusesExistingNameIgnoringCase() throws {
        let p = try store.createProject(name: "Film")
        let lib = try store.tree(projectID: p.id)
        let first = try store.findOrCreateBin(parentID: lib.id, name: "A_9001_1C3S")
        XCTAssertTrue(first.created)
        let again = try store.findOrCreateBin(parentID: lib.id, name: " a_9001_1c3s ")
        XCTAssertFalse(again.created)
        XCTAssertEqual(again.node.id, first.node.id)
        XCTAssertEqual(again.node.name, "A_9001_1C3S", "si usa il nome già registrato: stessa cartella su disco")
        let day = try store.createDay(projectID: p.id, name: "D1")
        XCTAssertTrue(try store.findOrCreateBin(parentID: day.id, name: "A_9001_1C3S").created, "stesso nome in un'altra cartella = bin diverso")
        XCTAssertThrowsError(try store.findOrCreateBin(parentID: lib.id, name: "con/barra"))
    }

    func testSuggestedBinNameFromSource() {
        XCTAssertEqual(NameValidator.suggestedBinName(fromSource: "A_9001_1C3S"), "A_9001_1C3S")
        XCTAssertEqual(NameValidator.suggestedBinName(fromSource: "CARD: 1/2"), "CARD_ 1_2")
        XCTAssertEqual(NameValidator.suggestedBinName(fromSource: "..hidden."), "hidden")
        XCTAssertEqual(NameValidator.suggestedBinName(fromSource: "/"), "_")
        XCTAssertNoThrow(try NameValidator.validated(NameValidator.suggestedBinName(fromSource: "NO NAME")))
    }

    func testBinTargetAndDestinationPath() throws {
        let p = try store.createProject(name: "Film")
        let day = try store.createDay(projectID: p.id, name: "DAY01_20261016")
        let bin = try store.createBin(parentID: day.id, name: "A_0001_1DET")
        let target = try XCTUnwrap(try store.binTarget(binID: bin.id))
        XCTAssertEqual(target.projectName, "Film")
        XCTAssertEqual(target.destinationRoot(under: URL(fileURLWithPath: "/Volumes/SSD1")).path,
                       "/Volumes/SSD1/A_0001_1DET", "su disco solo la cartella del bin")
        XCTAssertNil(try store.binTarget(binID: day.id), "un giorno non è un bin")
        XCTAssertNil(try store.binTarget(binID: 9999))
    }

    // MARK: Offload registrati

    private func runRealOffload(binID: Int64, dests: [URL], card: FakeCard,
                                corruptTarget: String? = nil, jobID: UUID = UUID()) throws -> OffloadResult {
        let scan = try SourceScanner.scan(root: card.root)
        let job = OffloadJob(id: jobID, sourceURL: card.root, destinationRoots: dests)
        try store.beginOffload(jobID: job.id, binID: binID, sourcePath: card.root.path, destinations: dests.map(\.path))
        let engine = OffloadEngine(job: job, scan: scan)
        if let corruptTarget {
            engine.onPhase = { phase in
                guard phase == .verifying else { return }
                let fd = open(dests[0].appendingPathComponent(corruptTarget + OffloadEngine.partialSuffix).path, O_RDWR)
                var b: UInt8 = 0; _ = pread(fd, &b, 1, 10); b ^= 1; _ = pwrite(fd, &b, 1, 10); close(fd)
            }
        }
        let result = engine.run()
        try store.finishOffload(result)
        return result
    }

    func testOffloadIsRegisteredInTheChosenBin() throws {
        let card = try FakeCard.create()
        let destBase = try TestSupport.makeTempDir("dest")
        defer {
            try? FileManager.default.removeItem(at: card.root.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: destBase)
        }
        let p = try store.createProject(name: "Film")
        let day = try store.createDay(projectID: p.id, name: "DAY01_20261016")
        let bin = try store.createBin(parentID: day.id, name: "A_0001_1DET")
        let other = try store.createBin(parentID: day.id, name: "B_0001_2XXX")
        let target = try XCTUnwrap(try store.binTarget(binID: bin.id))
        let root = target.destinationRoot(under: destBase)
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)

        let result = try runRealOffload(binID: bin.id, dests: [root], card: card)
        XCTAssertTrue(result.allOK)

        // media: .mov ×2, .ari, .mxf = 4; sidecar e altri file registrati ma non contati
        XCTAssertEqual(try store.projects()[0].clipCount, 4)
        let tree = try store.tree(projectID: p.id)
        XCTAssertEqual(tree.clipCount, 4)
        XCTAssertEqual(tree.children?[0].clipCount, 4)
        XCTAssertEqual(tree.children?[0].children?.first { $0.id == bin.id }?.clipCount, 4)
        XCTAssertEqual(tree.children?[0].children?.first { $0.id == other.id }?.clipCount, 0)

        let clips = try store.clips(underNode: bin.id)
        XCTAssertEqual(Set(clips.map(\.name)), ["A001C001_240101_R1AB.mov", "A001C002_240101_R1AB.mov", "A001C003.ari", "C0001.MXF"])
        XCTAssertTrue(clips.allSatisfy { $0.status == "ok" && $0.sourceHash?.count == 16 && $0.binName == "A_0001_1DET" && $0.dayName == "DAY01_20261016" })
        XCTAssertEqual(try store.clips(underNode: bin.id, mediaOnly: false).count, card.files.count)
        XCTAssertEqual(try store.clips(underNode: day.id).count, 4)
        XCTAssertEqual(try store.clips(underNode: tree.id).count, 4)
        XCTAssertEqual(try store.clips(underNode: other.id).count, 0)

        let offloads = try store.offloads(binID: bin.id)
        XCTAssertEqual(offloads.count, 1)
        XCTAssertEqual(offloads[0].outcome, "completed")
        XCTAssertTrue(offloads[0].allOK)
        XCTAssertEqual(offloads[0].destinations, [root.path])
        XCTAssertEqual(offloads[0].sourcePath, card.root.path)
    }

    func testClipWithMismatchIsRecordedButNotCounted() throws {
        let card = try FakeCard.create()
        let destBase = try TestSupport.makeTempDir("dest")
        defer {
            try? FileManager.default.removeItem(at: card.root.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: destBase)
        }
        let p = try store.createProject(name: "Film")
        let bin = try store.createBin(parentID: try store.createDay(projectID: p.id, name: "D1").id, name: "B1")
        let result = try runRealOffload(binID: bin.id, dests: [destBase.appendingPathComponent("out")], card: card,
                                        corruptTarget: "CLIP/C0001.MXF")
        XCTAssertFalse(result.allOK)
        XCTAssertEqual(try store.projects()[0].clipCount, 3, "un MISMATCH non deve contare come clip valida")
        let bad = try XCTUnwrap(try store.clips(underNode: bin.id).first { $0.name == "C0001.MXF" })
        XCTAssertEqual(bad.status, "mismatch")
        XCTAssertEqual(try store.offloads(binID: bin.id)[0].allOK, false)
    }

    func testResumeKeepsSingleOffloadRecordAndPreservesMetadata() throws {
        let card = try FakeCard.create()
        let destBase = try TestSupport.makeTempDir("dest")
        defer {
            try? FileManager.default.removeItem(at: card.root.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: destBase)
        }
        let p = try store.createProject(name: "Film")
        let bin = try store.createBin(parentID: try store.createDay(projectID: p.id, name: "D1").id, name: "B1")
        let dest = destBase.appendingPathComponent("out")
        let jobID = UUID()
        _ = try runRealOffload(binID: bin.id, dests: [dest], card: card, jobID: jobID)
        let clip = try XCTUnwrap(try store.clips(underNode: bin.id).first)
        try store.updateMetadata(clipID: clip.id, merging: ["iso": "800", "codec": "ARRIRAW"])
        // stesso job di nuovo (Riprendi / rilancio): nessun duplicato, i metadata restano
        _ = try runRealOffload(binID: bin.id, dests: [dest], card: card, jobID: jobID)
        XCTAssertEqual(try store.offloads(binID: bin.id).count, 1)
        let clips = try store.clips(underNode: bin.id)
        XCTAssertEqual(clips.count, 4)
        XCTAssertEqual(clips.first { $0.id == clip.id }?.metadata, ["iso": "800", "codec": "ARRIRAW"])
        XCTAssertEqual(clips.filter { $0.metadata.isEmpty }.count, 3, "senza metadata resta vuoto (l'interfaccia mostra N/D)")
        XCTAssertThrowsError(try store.updateMetadata(clipID: 99999, merging: [:]))
    }

    func testPreflightFailureLeavesNoOffloadRecord() throws {
        let card = try FakeCard.create()
        defer { try? FileManager.default.removeItem(at: card.root.deletingLastPathComponent()) }
        let p = try store.createProject(name: "Film")
        let bin = try store.createBin(parentID: try store.createDay(projectID: p.id, name: "D1").id, name: "B1")
        let result = try runRealOffload(binID: bin.id, dests: [URL(fileURLWithPath: "/volume-inesistente/x/y")], card: card)
        XCTAssertEqual(result.outcome, .preflightFailed)
        XCTAssertEqual(try store.offloads(binID: bin.id).count, 0)
    }

    func testDeletingBinRemovesItsOffloadsAndClipsFromDatabase() throws {
        let card = try FakeCard.create()
        let destBase = try TestSupport.makeTempDir("dest")
        defer {
            try? FileManager.default.removeItem(at: card.root.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: destBase)
        }
        let p = try store.createProject(name: "Film")
        let day = try store.createDay(projectID: p.id, name: "D1")
        let bin = try store.createBin(parentID: day.id, name: "B1")
        _ = try runRealOffload(binID: bin.id, dests: [destBase.appendingPathComponent("out")], card: card)
        XCTAssertEqual(try store.deletionImpact(nodeID: day.id), .init(bins: 1, offloads: 1, clips: card.files.count))
        try store.deleteNode(id: day.id)
        XCTAssertEqual(try store.projects()[0].clipCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destBase.appendingPathComponent("out/CLIP/C0001.MXF").path),
                      "i file copiati su disco non vengono toccati")
    }

    // MARK: Persistenza

    func testDatabasePersistsOnDisk() throws {
        let dir = try TestSupport.makeTempDir("db")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("sub/teostack.sqlite").path
        do {
            let s = try ProjectStore(path: path)
            let p = try s.createProject(name: "Persistente")
            _ = try s.createDay(projectID: p.id, name: "DAY01_20261016")
        }
        let reopened = try ProjectStore(path: path)
        let list = try reopened.projects()
        XCTAssertEqual(list.map(\.name), ["Persistente"])
        XCTAssertEqual(try reopened.tree(projectID: list[0].id).children?.map(\.name), ["DAY01_20261016"])
    }
}

final class ClipColumnsTests: XCTestCase {
    private func clip(_ name: String, size: Int64, metadata: [String: String] = [:], hash: String? = "0123456789abcdef") -> ClipRecord {
        ClipRecord(id: 1, offloadID: 1, binID: 1, relativePath: "X/\(name)", name: name, size: size, sourceHash: hash,
                   status: "ok", destinationStatuses: ["ok"], isMedia: true, metadata: metadata,
                   offloadDate: Date(timeIntervalSince1970: 1_700_000_000), binName: "B1", dayName: "D1")
    }

    func testColumnIDsAreUniqueAndDefaultsExist() {
        let ids = ClipColumns.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(ClipColumns.defaultVisibleIDs.allSatisfy { ClipColumns.column(id: $0) != nil })
        for needed in ["sensorFPS", "ndFilter", "lookInfo", "lens", "iso", "whiteBalance", "timecode", "codec", "resolution"] {
            XCTAssertNotNil(ClipColumns.column(id: needed), needed)
        }
    }

    func testMissingMetadataShowsND() throws {
        let c = clip("a.mov", size: 10, metadata: ["iso": "800", "lens": "  "], hash: nil)
        XCTAssertEqual(ClipColumns.value(try XCTUnwrap(ClipColumns.column(id: "iso")), of: c), "800")
        XCTAssertEqual(ClipColumns.value(try XCTUnwrap(ClipColumns.column(id: "lens")), of: c), "N/D")
        XCTAssertEqual(ClipColumns.value(try XCTUnwrap(ClipColumns.column(id: "timecode")), of: c), "N/D")
        XCTAssertEqual(ClipColumns.value(try XCTUnwrap(ClipColumns.column(id: "hash")), of: c), "N/D")
        XCTAssertEqual(ClipColumns.value(try XCTUnwrap(ClipColumns.column(id: "status")), of: c), "OK")
    }

    func testSorting() throws {
        let clips = [clip("C10.mov", size: 5), clip("C2.mov", size: 50), clip("C1.mov", size: 500)]
        let name = try XCTUnwrap(ClipColumns.column(id: "name")), size = try XCTUnwrap(ClipColumns.column(id: "size"))
        XCTAssertEqual(ClipColumns.sorted(clips, by: name, ascending: true).map(\.name), ["C1.mov", "C2.mov", "C10.mov"])
        XCTAssertEqual(ClipColumns.sorted(clips, by: size, ascending: false).map(\.size), [500, 50, 5])
    }
}
