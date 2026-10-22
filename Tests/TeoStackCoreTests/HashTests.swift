import XCTest
@testable import TeoStackCore

final class HashTests: XCTestCase {
    func testKnownVectors() {
        // Vettori ufficiali XXH64 con seed 0
        let h = XXH64Hasher()
        XCTAssertEqual(h.hexDigest(), "ef46db3751d8e999")           // stringa vuota
        let h2 = XXH64Hasher()
        h2.update(Data("a".utf8))
        XCTAssertEqual(h2.hexDigest(), "d24ec4f1a98c6e5b")
        let h3 = XXH64Hasher()
        h3.update(Data("abc".utf8))
        XCTAssertEqual(h3.hexDigest(), "44bc2cf5ad770999")
    }

    func testHexIsAlwaysSixteenDigits() {
        XCTAssertEqual(XXH64Hasher.hex(0), "0000000000000000")
        XCTAssertEqual(XXH64Hasher.hex(0xAB), "00000000000000ab")
    }

    func testStreamingEqualsOneShot() {
        var gen = SeededGenerator(seed: 42)
        let data = Data((0..<100_003).map { _ in UInt8(truncatingIfNeeded: gen.next()) })
        let one = XXH64Hasher(); one.update(data)
        let streamed = XXH64Hasher()
        var offset = 0
        for step in [1, 7, 31, 32, 33, 4096, 65536, 1000] {
            let end = min(data.count, offset + step)
            streamed.update(data.subdata(in: offset..<end)); offset = end
        }
        streamed.update(data.subdata(in: offset..<data.count))
        XCTAssertEqual(one.hexDigest(), streamed.hexDigest())
    }

    /// Confronto con il programma di riferimento xxhsum su dimensioni "di confine".
    func testMatchesXxhsum() throws {
        let dir = try TestSupport.makeTempDir("hash")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bufferSize = 8 * 1024 * 1024
        let sizes = [0, 1, 3, 4, 7, 8, 31, 32, 33, 63, 64, 65, 4095, 4096, 4097,
                     bufferSize - 1, bufferSize, bufferSize + 1, 3 * bufferSize + 12345]
        for (i, size) in sizes.enumerated() {
            let url = dir.appendingPathComponent("f\(i).bin")
            try TestSupport.writeRandomFile(url, size: size, seed: UInt64(1000 + i))
            let expected = try TestSupport.xxhsumHash(of: url)
            XCTAssertEqual(try XXH64Hasher.hashOfFile(at: url), expected, "dimensione \(size)")
            // anche con un buffer piccolo e non multiplo di 32
            XCTAssertEqual(try XXH64Hasher.hashOfFile(at: url, bufferSize: 100_003), expected, "dimensione \(size), buffer 100003")
        }
    }

    func testVerifierUncachedMatchesCached() throws {
        let dir = try TestSupport.makeTempDir("hash")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("x.bin")
        try TestSupport.writeRandomFile(url, size: 5_000_000, seed: 7)
        let a = try FileVerifier.hash(path: url.path, uncached: true)
        let b = try FileVerifier.hash(path: url.path, uncached: false)
        XCTAssertEqual(a.hash, b.hash)
        XCTAssertEqual(a.bytes, 5_000_000)
    }

    func testVerifierReportsMissingFile() {
        XCTAssertThrowsError(try FileVerifier.hash(path: "/nonexistent/file", uncached: true)) { error in
            XCTAssertEqual((error as? DiskIOError)?.code, ENOENT)
        }
    }
}

final class FileVerifierPipelineTests: XCTestCase {
    func testPipelinedHashMatchesWholeFileHashAtBufferBoundaries() throws {
        let dir = try TestSupport.makeTempDir("verifier")
        defer { try? FileManager.default.removeItem(at: dir) }
        let buffer = 4096
        for size in [0, 1, buffer - 1, buffer, buffer + 1, 3 * buffer, 3 * buffer + 17, 10 * buffer, 10 * buffer + 1] {
            let url = dir.appendingPathComponent("f\(size)")
            try TestSupport.writeRandomFile(url, size: size, seed: UInt64(size))
            let reference = XXH64Hasher()
            let data = try Data(contentsOf: url)
            data.withUnsafeBytes { reference.update($0.baseAddress!, count: data.count) }
            var progress = 0
            let (hash, bytes) = try FileVerifier.hash(path: url.path, uncached: true, bufferSize: buffer, onProgress: { progress += $0 })
            XCTAssertEqual(hash, reference.hexDigest(), "size \(size)")
            XCTAssertEqual(bytes, Int64(size))
            XCTAssertEqual(progress, size)
        }
    }

    func testCancellationAndMissingFileDoNotHang() throws {
        let dir = try TestSupport.makeTempDir("verifier")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("big")
        try TestSupport.writeRandomFile(url, size: 4_000_000, seed: 7)
        var calls = 0
        XCTAssertThrowsError(try FileVerifier.hash(path: url.path, uncached: true, bufferSize: 4096, isCancelled: { calls += 1; return calls > 5 })) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertThrowsError(try FileVerifier.hash(path: dir.appendingPathComponent("nope").path, uncached: true))
    }
}
