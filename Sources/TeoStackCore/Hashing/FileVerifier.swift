import Foundation

/// Rilettura e hash di un file con lettura non in cache.
public enum FileVerifier {
    public static let defaultBufferSize = 8 * 1024 * 1024

    /// Legge il file per intero (F_NOCACHE se `uncached`), calcola XXH64 e restituisce (hash, byte letti).
    /// `onProgress` riceve i byte appena letti; `isCancelled` interrompe la lettura (lancia CancellationError).
    public static func hash(path: String,
                            uncached: Bool,
                            bufferSize: Int = defaultBufferSize,
                            isCancelled: () -> Bool = { false },
                            onProgress: (Int) -> Void = { _ in }) throws -> (hash: String, bytes: Int64) {
        let fd = try DiskIO.openForReading(path: path, uncached: uncached)
        defer { close(fd) }
        let buffer = DiskIO.allocateBuffer(size: bufferSize)
        defer { free(buffer) }
        let hasher = XXH64Hasher()
        var total: Int64 = 0
        while true {
            if isCancelled() { throw CancellationError() }
            let n = try DiskIO.readFully(fd: fd, into: buffer, count: bufferSize, path: path)
            if n == 0 { break }
            hasher.update(buffer, count: n)
            total += Int64(n)
            if uncached { DiskIO.dropCachedPages(fd: fd, offset: total - Int64(n), length: n) }
            onProgress(n)
            if n < bufferSize { break }
        }
        return (hasher.hexDigest(), total)
    }
}
