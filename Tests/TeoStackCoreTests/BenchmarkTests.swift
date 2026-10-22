import XCTest
@testable import TeoStackCore

/// Misura la velocità reale dell'offload. Non gira nei test normali:
///   TEOSTACK_BENCH=1 swift test --filter BenchmarkTests            (dati in cartelle temporanee)
///   TEOSTACK_BENCH=1 TEOSTACK_BENCH_MB=8000 TEOSTACK_BENCH_SRC=/Volumes/SCHEDA_PROVA TEOSTACK_BENCH_DST=/Volumes/SSD1 swift test --filter BenchmarkTests
/// Con TEOSTACK_BENCH_SRC si usa una cartella già esistente come sorgente (letta soltanto).
final class BenchmarkTests: XCTestCase {
    func testOffloadThroughput() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["TEOSTACK_BENCH"] == "1", "benchmark: impostare TEOSTACK_BENCH=1")
        let megabytes = Int(env["TEOSTACK_BENCH_MB"] ?? "") ?? 1500
        let tmp = try TestSupport.makeTempDir("bench")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let source: URL
        if let s = env["TEOSTACK_BENCH_SRC"] { source = URL(fileURLWithPath: s) } else {
            source = tmp.appendingPathComponent("card")
            let big = megabytes == 0 ? 0 : max(1, megabytes / 500)
            for i in 0..<big { try TestSupport.writeRandomFile(source.appendingPathComponent("CLIP/A\(i).mxf"), size: megabytes * 1_000_000 / max(big, 1), seed: UInt64(i)) }
            for i in 0..<(Int(env["TEOSTACK_BENCH_SMALL"] ?? "") ?? 300) { try TestSupport.writeRandomFile(source.appendingPathComponent("SIDE/s\(i).xml"), size: 4_000 + i, seed: UInt64(1000 + i)) }
        }
        let destBase = env["TEOSTACK_BENCH_DST"].map { URL(fileURLWithPath: $0).appendingPathComponent("teostack-bench-\(UUID().uuidString)") } ?? tmp
        defer { if env["TEOSTACK_BENCH_DST"] != nil { try? FileManager.default.removeItem(at: destBase) } }
        let dests = (1...2).map { destBase.appendingPathComponent("dest\($0)") }
        for d in dests { try FileManager.default.createDirectory(at: d.deletingLastPathComponent(), withIntermediateDirectories: true) }

        let scan = try SourceScanner.scan(root: source)
        let job = OffloadJob(sourceURL: source, destinationRoots: dests)
        let engine = OffloadEngine(job: job, scan: scan)
        let start = Date()
        var verifyStart: Date?
        engine.onPhase = { if $0 == .verifying { verifyStart = Date() } }
        let result = engine.run()
        let total = Date().timeIntervalSince(start)
        XCTAssertEqual(result.outcome, .completed)
        XCTAssertTrue(result.allOK)
        let mb = Double(scan.totalSize) / 1_000_000
        let copyTime = verifyStart.map { $0.timeIntervalSince(start) } ?? total
        print(String(format: "BENCH files=%d size=%.0f MB | copia %.2fs (%.0f MB/s) | verifica %.2fs | totale %.2fs (%.0f MB/s effettivi, 2 destinazioni)",
                     scan.files.count, mb, copyTime, mb / copyTime, total - copyTime, total, mb / total))
    }
}
