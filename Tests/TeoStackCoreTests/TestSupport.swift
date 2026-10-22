import Foundation
import XCTest
@testable import TeoStackCore

enum TestSupport {
    static func makeTempDir(_ name: String = "teostack") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// File con contenuto pseudo-casuale deterministico (seed) – utile per riprodurre i test.
    static func writeRandomFile(_ url: URL, size: Int, seed: UInt64) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var gen = SeededGenerator(seed: seed)
        var data = Data(count: size)
        data.withUnsafeMutableBytes { raw in
            let words = raw.bindMemory(to: UInt64.self)
            for i in 0..<words.count { words[i] = gen.next() }
            var tail = words.count * 8
            while tail < raw.count { raw[tail] = UInt8(truncatingIfNeeded: gen.next()); tail += 1 }
        }
        try data.write(to: url)
    }

    /// Cerca xxhsum (installare con `brew install xxhash` su macOS, `apt install xxhash` su Linux).
    static func xxhsumPath() -> String? {
        ["/opt/homebrew/bin/xxhsum", "/usr/local/bin/xxhsum", "/usr/bin/xxhsum", "/opt/local/bin/xxhsum"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// XXH64 calcolato dal programma di riferimento `xxhsum -H1` (XXH64).
    static func xxhsumHash(of url: URL) throws -> String {
        guard let tool = xxhsumPath() else { throw XCTSkip("xxhsum non trovato: installarlo (brew install xxhash)") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = ["-H1", url.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(decoding: data, as: UTF8.self)
        return String(out.split(separator: " ").first ?? "")
    }

    static func contentsEqual(_ a: URL, _ b: URL) -> Bool {
        FileManager.default.contentsEqual(atPath: a.path, andPath: b.path)
    }

    /// Elenco ordinato (percorso relativo, dimensione, data di modifica) di una cartella, per confrontare "prima/dopo".
    static func snapshot(of root: URL) throws -> [String] {
        let scan = try SourceScanner.scan(root: root)
        return scan.files.map { "\($0.relativePath)|\($0.size)|\($0.modificationDate.timeIntervalSince1970)" }
            + scan.directories.map { "D:\($0.relativePath)|\($0.modificationDate.timeIntervalSince1970)" }
    }

    static func allFiles(under root: URL) -> [String] {
        guard let e = FileManager.default.enumerator(atPath: root.path) else { return [] }
        return (e.allObjects as? [String] ?? []).sorted()
    }
}

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {   // splitmix64
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Scheda finta con la struttura di un girato (cartelle annidate, file vuoto, file più grandi di un chunk).
struct FakeCard {
    let root: URL
    let files: [(path: String, size: Int)] = [
        ("A001R2EC/A001C001_240101_R1AB.mov", 3_000_000),
        ("A001R2EC/A001C002_240101_R1AB.mov", 1_234_567),
        ("A001R2EC/sub/deep/A001C003.ari", 20_000_001),
        ("CLIP/C0001.MXF", 5_000_000),
        ("CLIP/C0001M01.XML", 1_500),
        ("empty.bin", 0),
        ("tiny.txt", 1),
    ]

    static func create() throws -> FakeCard {
        let root = try TestSupport.makeTempDir("card").appendingPathComponent("A001_CARD", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let card = FakeCard(root: root)
        for (i, f) in card.files.enumerated() {
            try TestSupport.writeRandomFile(root.appendingPathComponent(f.path), size: f.size, seed: UInt64(i + 1))
        }
        // date diverse e riconoscibili
        for (i, f) in card.files.enumerated() {
            let d = Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 1000 + 0.5)
            try FileManager.default.setAttributes([.modificationDate: d], ofItemAtPath: root.appendingPathComponent(f.path).path)
        }
        return card
    }
}

extension OffloadEngine {
    /// Esegue `action` quando il file è stato scritto sulla destinazione `d` ma non ancora riletto: funziona uguale con la verifica
    /// sovrapposta alla copia o a copia finita (`onPhase(.verifying)` non basta più, la verifica può partire prima).
    func onCopied(_ relativePath: String, destination d: Int = 0, _ action: @escaping () -> Void) {
        onFileUpdate = { [scan] update in
            if update.status == .copied, update.destinationIndex == d, scan.files[update.fileIndex].relativePath == relativePath { action() }
        }
    }
}
