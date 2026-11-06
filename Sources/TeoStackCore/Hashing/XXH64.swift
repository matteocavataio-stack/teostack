import Foundation
import CXXHash

/// Hash XXH64 in streaming (libreria xxHash ufficiale, seed 0).
/// Il valore esadecimale è nella forma canonica di `xxhsum -H1` (16 cifre minuscole).
public final class XXH64Hasher {
    private var state: OpaquePointer?

    public init() {
        state = XXH64_createState()
        precondition(state != nil, "XXH64_createState ha restituito NULL")
        reset()
    }

    deinit {
        if let state { XXH64_freeState(state) }
    }

    /// Stato dell'hash in corso (serve a riprendere una copia da metà file). Valido solo per la stessa versione di xxHash: `restore` ne controlla la dimensione.
    public func exportState() -> Data? {
        let size = teo_xxh64_state_size()
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return teo_xxh64_export_state(state, base, size)
        }
        return written == size ? out : nil
    }

    /// Ripristina uno stato salvato con `exportState`. false se la dimensione non corrisponde (stato di un'altra versione): in quel caso non si usa.
    @discardableResult
    public func restore(_ saved: Data) -> Bool {
        saved.withUnsafeBytes { raw -> Bool in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            return teo_xxh64_import_state(state, base, saved.count) != 0
        }
    }

    public func reset() {
        _ = XXH64_reset(state, 0)
    }

    public func update(_ pointer: UnsafeRawPointer, count: Int) {
        guard count > 0 else { return }
        _ = XXH64_update(state, pointer, count)
    }

    public func update(_ data: Data) {
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress { update(base, count: raw.count) }
        }
    }

    public func digest() -> UInt64 {
        XXH64_digest(state)
    }

    public func hexDigest() -> String {
        XXH64Hasher.hex(digest())
    }

    public static func hex(_ value: UInt64) -> String {
        let h = String(value, radix: 16, uppercase: false)
        return String(repeating: "0", count: max(0, 16 - h.count)) + h
    }

    /// Hash di un file letto in streaming (nessuna garanzia di lettura da disco: per la verifica usare `FileVerifier`).
    public static func hashOfFile(at url: URL, bufferSize: Int = 8 * 1024 * 1024) throws -> String {
        let (hash, _) = try FileVerifier.hash(path: url.path, uncached: false, bufferSize: bufferSize)
        return hash
    }
}
