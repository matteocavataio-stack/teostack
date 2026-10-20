import XCTest
@testable import TeoStackCore

final class CryptoHelperTests: XCTestCase {
    private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    func testSHA512Vectors() {
        XCTAssertEqual(hex(SHA512.hash(Data("abc".utf8))),
                       "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")
        XCTAssertEqual(hex(SHA512.hash(Data())),
                       "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e")
        // più blocchi e confini di padding
        let long = Data(repeating: 0x61, count: 1_000_000)
        XCTAssertEqual(hex(SHA512.hash(long)),
                       "e718483d0ce769644e2e42c7bc15b4638e1f98b13b2044285632a803afa973ebde0ff244877ea60a4cb0432ce577c31beb009c5c2c49aa2e4eadb217ad8cc09b")
        for n in [111, 112, 113, 127, 128, 129, 239, 240, 256] {
            XCTAssertEqual(SHA512.hash(Data(repeating: 0x42, count: n)).count, 64)
        }
    }

    func testC4IDsMatchReferenceImplementation() {
        XCTAssertEqual(C4.id(of: Data()), "c459dsjfscH38cYeXXYogktxf4Cd9ibshE3BHUo6a58hBXmRQdZrAkZzsWcbWtDg5oQstpDuni4Hirj75GEmTc1sFT")
        XCTAssertEqual(C4.id(of: Data("abc".utf8)), "c45S4rnaTNWonxss1u8LzsaJdEph1AJhWUF4sh2waXKMsutyfAxg4ybUeuXVWS9HdNcEypmeXn8FZGonD4w1rj9DZp")
        XCTAssertEqual(C4.id(of: Data("abc".utf8)).count, 90)
    }
}

final class ASCMHLTests: ReportTestCase {
    /// Strumento ufficiale `ascmhl` (pip install ascmhl): da PATH o dalla variabile ASCMHL_BIN.
    private func officialTool() -> String? {
        if let p = ProcessInfo.processInfo.environment["ASCMHL_BIN"], FileManager.default.isExecutableFile(atPath: p) { return p }
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let c = String(dir) + "/ascmhl"
            if FileManager.default.isExecutableFile(atPath: c) { return c }
        }
        return nil
    }

    private func runOfficial(_ args: [String]) throws -> (status: Int32, output: String) {
        guard let tool = officialTool() else { throw XCTSkip("strumento ufficiale ascmhl non trovato (pip install ascmhl)") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        try p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (p.terminationStatus, out)
    }

    /// Il comando `verify` è nel pacchetto `ascmhl` ma non nel CLI 1.2: lo si richiama con lo stesso Python dell'eseguibile.
    private func runVerify(_ args: [String]) throws -> (status: Int32, output: String) {
        guard let tool = officialTool() else { throw XCTSkip("strumento ufficiale ascmhl non trovato (pip install ascmhl)") }
        let python = (tool as NSString).deletingLastPathComponent + "/python"
        guard FileManager.default.isExecutableFile(atPath: python) else { throw XCTSkip("python di ascmhl non trovato accanto a \(tool)") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = ["-c", "from ascmhl.commands import verify; verify()"] + args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        try p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (p.terminationStatus, out)
    }

    private func entries(in root: URL, tree: [(String, Int)]) throws -> [MHLFileEntry] {
        try tree.map { (rel, size) in
            let url = root.appendingPathComponent(rel)
            try TestSupport.writeRandomFile(url, size: size, seed: UInt64(rel.hashValue & 0xFFFF))
            let st = try DiskIO.lstatInfo(path: url.path)
            return MHLFileEntry(relativePath: rel, size: st.size, modified: st.times.modification,
                                xxh64: try XXH64Hasher.hashOfFile(at: url), hashDate: Date())
        }
    }

    func testFirstGenerationIsAcceptedByOfficialTool() throws {
        let root = base.appendingPathComponent("a001", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files = try entries(in: root, tree: [("A001C001.mov", 3000), ("CLIP/C0001.MXF", 5000), ("CLIP/sub/deep/x.ari", 70000), ("empty.bin", 0), ("Città àè.txt", 10)])
        var options = MHLOptions()
        options.author = "Mario Rossi"
        options.comment = "Offload di prova"
        let out = try ASCMHL.write(root: root, files: files, options: options)
        XCTAssertEqual(out.generation, 1)
        XCTAssertEqual(out.fileCount, 5)
        XCTAssertTrue(out.failedFiles.isEmpty)
        XCTAssertTrue((out.mhlPath as NSString).lastPathComponent.hasPrefix("0001_a001_"))
        XCTAssertTrue(out.mhlPath.hasSuffix("Z.mhl"))

        let verify = try runVerify(["-v", root.path])
        XCTAssertEqual(verify.status, 0, verify.output)
        XCTAssertTrue(verify.output.contains("OK") || !verify.output.contains("ERROR"), verify.output)
        // anche la verifica della catena (hash C4 del file .mhl)
        let chain = try runVerify(["-v", "-dh", "-h", "xxh64", root.path])
        XCTAssertEqual(chain.status, 0, chain.output)
        let xml = try String(contentsOfFile: out.mhlPath, encoding: .utf8)
        XCTAssertTrue(xml.contains("<author>Mario Rossi</author>"))
        XCTAssertTrue(xml.contains("action=\"original\""))
    }

    func testOfficialToolDetectsCorruptionInOurMHL() throws {
        let root = base.appendingPathComponent("a002", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files = try entries(in: root, tree: [("a.mov", 4000), ("sub/b.mxf", 9000)])
        _ = try ASCMHL.write(root: root, files: files)
        let before = try runVerify([root.path])        // (un XCTSkip dentro XCTAssert verrebbe scambiato per un errore: lo valuto prima)
        XCTAssertEqual(before.status, 0, before.output)
        // corrompo un byte: lo strumento ufficiale deve accorgersene (prova che il test non è banale)
        let fd = open(root.appendingPathComponent("sub/b.mxf").path, O_RDWR)
        var b: UInt8 = 0; _ = pread(fd, &b, 1, 100); b ^= 1; _ = pwrite(fd, &b, 1, 100); close(fd)
        let after = try runVerify([root.path])
        XCTAssertNotEqual(after.status, 0, "lo strumento ufficiale deve segnalare il byte corrotto: \(after.output)")
    }

    func testSecondGenerationAppendsToChainAndVerifies() throws {
        let root = base.appendingPathComponent("a003", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var files = try entries(in: root, tree: [("a.mov", 4000), ("sub/b.mxf", 9000)])
        var opt = MHLOptions(); opt.now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try ASCMHL.write(root: root, files: files, options: opt)
        let firstData = try Data(contentsOf: URL(fileURLWithPath: first.mhlPath))

        files += try entries(in: root, tree: [("sub/c.mov", 777)])
        opt.now = Date(timeIntervalSince1970: 1_800_000_100)
        let second = try ASCMHL.write(root: root, files: files, options: opt)
        XCTAssertEqual(second.generation, 2)
        XCTAssertTrue(second.failedFiles.isEmpty)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: first.mhlPath)), firstData, "la generazione precedente non deve cambiare")

        let xml = try String(contentsOfFile: second.mhlPath, encoding: .utf8)
        XCTAssertTrue(xml.contains("action=\"verified\""), "i file già presenti risultano verificati")
        XCTAssertTrue(xml.contains("action=\"original\""), "il file nuovo è originale")
        let chain = try String(contentsOfFile: second.chainPath, encoding: .utf8)
        XCTAssertTrue(chain.contains("sequencenr=\"1\"") && chain.contains("sequencenr=\"2\""))
        let verify = try runVerify(["-v", root.path])
        XCTAssertEqual(verify.status, 0, verify.output)
    }

    func testChangedFileIsMarkedFailedInNewGeneration() throws {
        let root = base.appendingPathComponent("a004", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var files = try entries(in: root, tree: [("a.mov", 4000)])
        var opt = MHLOptions(); opt.now = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try ASCMHL.write(root: root, files: files, options: opt)
        files[0].xxh64 = "0000000000000001"       // l'hash ora è diverso da quello della generazione 1
        opt.now = Date(timeIntervalSince1970: 1_800_000_100)
        let second = try ASCMHL.write(root: root, files: files, options: opt)
        XCTAssertEqual(second.failedFiles, ["a.mov"])
        XCTAssertTrue(try String(contentsOfFile: second.mhlPath, encoding: .utf8).contains("action=\"failed\""))
    }

    func testOurSecondGenerationOnTopOfOfficialFirstGeneration() throws {
        let root = base.appendingPathComponent("a005", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var files = try entries(in: root, tree: [("a.mov", 4000), ("sub/b.mxf", 9000)])
        let created = try runOfficial(["create", "-h", "xxh64", root.path])
        XCTAssertEqual(created.status, 0, created.output)
        files += try entries(in: root, tree: [("new.mov", 1234)])
        var opt = MHLOptions(); opt.now = Date().addingTimeInterval(5)
        let out = try ASCMHL.write(root: root, files: files, options: opt)
        XCTAssertEqual(out.generation, 2)
        XCTAssertTrue(out.failedFiles.isEmpty)
        let verify = try runVerify(["-v", root.path])
        XCTAssertEqual(verify.status, 0, verify.output)
    }

    func testRefusesEmptyFileList() {
        XCTAssertThrowsError(try ASCMHL.write(root: base, files: []))
    }

    func testTargetsFromDatabaseOnlyContainVerifiedFilesOnDisk() throws {
        try offload(to: bin)
        // un file in più sul disco che l'app non ha verificato, e un file registrato OK che sparisce
        try Data("extra".utf8).write(to: destinations[0].appendingPathComponent("non-verificato.txt"))
        try FileManager.default.removeItem(at: destinations[1].appendingPathComponent("CLIP/C0001.MXF"))
        let targets = try MHLTargets.collect(store: store, nodeID: bin.id)
        XCTAssertEqual(targets.map(\.root), destinations.map(\.path))
        XCTAssertEqual(targets[0].entries.count, card.files.count)
        XCTAssertEqual(targets[0].unlistedOnDisk, 1)
        XCTAssertEqual(targets[1].entries.count, card.files.count - 1)
        XCTAssertEqual(targets[1].skipped.count, 1)
        XCTAssertTrue(targets[1].skipped[0].contains("C0001.MXF"))
        // l'hash inserito è quello verificato dell'offload
        let mxf = try XCTUnwrap(targets[0].entries.first { $0.relativePath == "CLIP/C0001.MXF" })
        XCTAssertEqual(mxf.xxh64, try TestSupport.xxhsumHash(of: card.root.appendingPathComponent("CLIP/C0001.MXF")))
    }

    func testRealOffloadFolderGetsAValidMHL() throws {
        try offload(to: bin)
        let target = try XCTUnwrap(try MHLTargets.collect(store: store, nodeID: bin.id).first)
        let out = try ASCMHL.write(root: URL(fileURLWithPath: target.root), files: target.entries)
        XCTAssertEqual(out.fileCount, card.files.count)
        let verify = try runVerify(["-v", target.root])
        XCTAssertEqual(verify.status, 0, verify.output)
    }
}
