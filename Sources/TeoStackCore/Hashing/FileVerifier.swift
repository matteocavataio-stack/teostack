import Foundation

/// Rilettura e hash di un file con lettura non in cache.
public enum FileVerifier {
    public static let defaultBufferSize = 8 * 1024 * 1024
    private static let bufferCount = 3

    /// Legge il file per intero (F_NOCACHE se `uncached`), calcola XXH64 e restituisce (hash, byte letti).
    /// La lettura e il calcolo dell'hash avvengono in parallelo (un thread legge il blocco successivo mentre l'altro calcola l'hash del precedente).
    /// Con `limit` si leggono solo i primi `limit` byte (per ricontrollare la parte già scritta di una copia interrotta).
    /// `onProgress` riceve i byte appena letti; `isCancelled` interrompe la lettura (lancia CancellationError).
    public static func hash(path: String,
                            uncached: Bool,
                            bufferSize: Int = defaultBufferSize,
                            limit: Int64? = nil,
                            isCancelled: () -> Bool = { false },
                            onProgress: (Int) -> Void = { _ in }) throws -> (hash: String, bytes: Int64) {
        let fd = try DiskIO.openForReading(path: path, uncached: uncached)
        defer { close(fd) }
        let buffers = (0..<bufferCount).map { _ in DiskIO.allocateBuffer(size: bufferSize) }
        defer { buffers.forEach { free($0) } }

        let freeSlots = DispatchSemaphore(value: bufferCount)
        let filledSlots = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var queue: [(slot: Int, count: Int)] = []     // count < 0: errore di lettura
        var readError: Error?
        var stop = false
        let reader = DispatchGroup()

        DispatchQueue.global(qos: .userInitiated).async(group: reader) {
            var slot = 0
            var offset: Int64 = 0
            while true {
                freeSlots.wait()
                lock.lock(); let stopped = stop; lock.unlock()
                if stopped { return }
                var want = bufferSize
                if let limit {
                    let remaining = limit - offset
                    if remaining <= 0 {
                        lock.lock(); queue.append((slot, 0)); lock.unlock()
                        filledSlots.signal()
                        return
                    }
                    want = Int(min(Int64(bufferSize), remaining))
                }
                let n: Int
                do {
                    n = try DiskIO.readFully(fd: fd, into: buffers[slot], count: want, path: path)
                } catch {
                    lock.lock(); readError = error; queue.append((slot, -1)); lock.unlock()
                    filledSlots.signal()
                    return
                }
                if uncached && n > 0 { DiskIO.dropCachedPages(fd: fd, offset: offset, length: n) }
                offset += Int64(n)
                lock.lock(); queue.append((slot, n)); lock.unlock()
                filledSlots.signal()
                if n < want { return }
                slot = (slot + 1) % bufferCount
            }
        }

        /// Ferma il lettore e attende che abbia finito prima di liberare i buffer.
        func shutDownReader() {
            lock.lock(); stop = true; lock.unlock()
            for _ in 0..<bufferCount { freeSlots.signal() }
            reader.wait()
            // Un semaforo non può essere liberato con un valore inferiore a quello iniziale (libdispatch lo considera un errore e il programma si chiude):
            // il lettore, svegliato per uscire, ne ha consumato uno. Si riporta il valore sopra l'iniziale.
            for _ in 0..<bufferCount { freeSlots.signal() }
        }

        let hasher = XXH64Hasher()
        var total: Int64 = 0
        while true {
            filledSlots.wait()
            if isCancelled() { shutDownReader(); throw CancellationError() }
            lock.lock(); let item = queue.removeFirst(); let error = readError; lock.unlock()
            if item.count < 0 { shutDownReader(); throw error ?? DiskIOError(code: EIO, operation: tr("Lettura"), path: path) }
            if item.count == 0 { break }
            hasher.update(buffers[item.slot], count: item.count)
            total += Int64(item.count)
            onProgress(item.count)
            freeSlots.signal()
            if item.count < bufferSize { break }
        }
        shutDownReader()
        return (hasher.hexDigest(), total)
    }
}
