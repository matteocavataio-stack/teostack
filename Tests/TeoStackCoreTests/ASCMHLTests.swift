import XCTest
@testable import TeoStackCore

final class C4IDTests: XCTestCase {
    func testSHA512Vectors() {
        func hex(_ d: Data) -> String { SHA512.hash(d).map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(hex(Data()).prefix(16), "cf83e1357eefb8bd")
        XCTAssertEqual(hex(Data("abc".utf8)).prefix(16), "ddaf35a193617aba")
        XCTAssertEqual(hex(Data(repeating: 0x78, count: 1000)).prefix(16), "ae13575c5d98bfa6")
    }

    func testC4Format() {
        let id = C4ID.string(for: Data("abc".utf8))
        XCTAssertEqual(id.count, 90)
        XCTAssertTrue(id.hasPrefix("c4"))
        // valore calcolato dallo strumento ufficiale ascmhl (hasher.C4) per "foo"
        XCTAssertEqual(C4ID.string(for: Data("foo".utf8)), "c45xZeXwMSpqXjpDumcHMA6mhoAmGHkUo7r9WmN2UgSEQzj9KjgseaQdkEJ11fGb5S1WEENcV3q8RFWwEeVpC7Fjk2")
    }
}

final class ASCMHLWriterTests: XCTestCase {
    private func makeTree() throws -> (root: URL, hashes: [String: String]) {
        let base = try TestSupport.makeTempDir("mhl")
        let root = base.appendingPathComponent("A001", isDirectory: true)
        try TestSupport.writeRandomFile(root.appendingPathComponent("clip1.mov"), size: 100_000, seed: 1)
        try TestSupport.writeRandomFile(root.appendingPathComponent("sub/clip2.mov"), size: 50_000, seed: 2)
        try TestSupport.writeRandomFile(root.appendingPathComponent("sub/deep/clip3.mxf"), size: 7, seed: 3)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
        var hashes: [String: String] = [:]
        for p in ["clip1.mov", "sub/clip2.mov", "sub/deep/clip3.mxf"] {
            hashes[p] = try XXH64Hasher.hashOfFile(at: root.appendingPathComponent(p))
        }
        return (root, hashes)
    }

    func testFirstGenerationAndChain() throws {
        let (root, hashes) = try makeTree()
        let result = try ASCMHLWriter.write(root: root, knownHashes: hashes, options: ASCMHLOptions(author: "Teo & <DIT>"))
        XCTAssertEqual(result.generation, 1)
        XCTAssertEqual(result.fileCount, 3)
        XCTAssertEqual(result.rehashedCount, 0)
        let xml = try String(contentsOf: result.file, encoding: .utf8)
        XCTAssertTrue(xml.contains("<author>Teo &amp; &lt;DIT&gt;</author>"))
        XCTAssertTrue(xml.contains("<process>transfer</process>"))
        XCTAssertEqual(xml.components(separatedBy: "action=\"original\"").count - 1, 3)
        let chain = try String(contentsOf: result.folder.appendingPathComponent("ascmhl_chain.xml"), encoding: .utf8)
        XCTAssertTrue(chain.contains(C4ID.string(for: try Data(contentsOf: result.file))))
        XCTAssertTrue(result.file.lastPathComponent.hasPrefix("0001_A001_"))
        if let keep = ProcessInfo.processInfo.environment["TEOSTACK_KEEP_MHL"] {
            try? FileManager.default.removeItem(atPath: keep)
            try FileManager.default.copyItem(at: root, to: URL(fileURLWithPath: keep))
        }
    }

    func testSecondGenerationVerifiesAndDetectsChange() throws {
        let (root, hashes) = try makeTree()
        _ = try ASCMHLWriter.write(root: root, knownHashes: hashes)
        // 2ª generazione: nessun hash noto, tutto viene riletto → «verified»
        let second = try ASCMHLWriter.write(root: root, knownHashes: [:], now: Date().addingTimeInterval(5))
        XCTAssertEqual(second.generation, 2)
        XCTAssertEqual(second.rehashedCount, 3)
        var xml = try String(contentsOf: second.file, encoding: .utf8)
        XCTAssertEqual(xml.components(separatedBy: "action=\"verified\"").count - 1, 3)
        // un file cambia → «failed»; un file nuovo → «original»
        try TestSupport.writeRandomFile(root.appendingPathComponent("clip1.mov"), size: 100_000, seed: 99)
        try TestSupport.writeRandomFile(root.appendingPathComponent("new.wav"), size: 10, seed: 5)
        let third = try ASCMHLWriter.write(root: root, knownHashes: [:], now: Date().addingTimeInterval(10))
        XCTAssertEqual(third.generation, 3)
        xml = try String(contentsOf: third.file, encoding: .utf8)
        XCTAssertEqual(xml.components(separatedBy: "action=\"failed\"").count - 1, 1)
        XCTAssertEqual(xml.components(separatedBy: "action=\"original\"").count - 1, 1)
        if let keep = ProcessInfo.processInfo.environment["TEOSTACK_KEEP_MHL3"] {
            try? FileManager.default.removeItem(atPath: keep)
            try FileManager.default.copyItem(at: root, to: URL(fileURLWithPath: keep))
        }
    }

    func testBrokenChainRefusesToWrite() throws {
        let (root, hashes) = try makeTree()
        let first = try ASCMHLWriter.write(root: root, knownHashes: hashes)
        try Data("<x".utf8).write(to: first.folder.appendingPathComponent("ascmhl_chain.xml"))
        XCTAssertThrowsError(try ASCMHLWriter.write(root: root, knownHashes: hashes, now: Date().addingTimeInterval(5)))
    }

    func testCancellationLeavesNothing() throws {
        let (root, hashes) = try makeTree()
        XCTAssertThrowsError(try ASCMHLWriter.write(root: root, knownHashes: hashes, isCancelled: { true }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ascmhl").path))
    }

    func testControlCharacterInNameRefusesToWrite() throws {
        let (root, hashes) = try makeTree()
        try Data("x".utf8).write(to: root.appendingPathComponent("bad\u{01}name.txt"))
        XCTAssertThrowsError(try ASCMHLWriter.write(root: root, knownHashes: hashes))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ascmhl").path))
    }
}
