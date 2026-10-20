import Foundation

/// Buffer condiviso tra il lettore e i writer delle destinazioni. Torna al pool quando tutti hanno finito.
final class Chunk {
    let buffer: UnsafeMutableRawPointer
    let capacity: Int
    var count = 0
    private var references = 0
    private let lock = NSLock()
    unowned let pool: ChunkPool

    init(capacity: Int, pool: ChunkPool) {
        self.capacity = capacity
        self.pool = pool
        buffer = DiskIO.allocateBuffer(size: capacity)
    }

    deinit { free(buffer) }

    func setReferences(_ n: Int) {
        lock.lock(); references = n; lock.unlock()
    }

    func release() {
        lock.lock()
        references -= 1
        let done = references <= 0
        lock.unlock()
        if done { pool.give(self) }
    }
}

/// Numero fisso di buffer: limita la memoria e dà "contropressione" al lettore se una destinazione è lenta.
final class ChunkPool {
    private var free: [Chunk] = []
    private let lock = NSLock()
    private let semaphore: DispatchSemaphore
    private var all: [Chunk] = []

    init(chunkSize: Int, count: Int) {
        semaphore = DispatchSemaphore(value: count)
        for _ in 0..<count {
            let c = Chunk(capacity: chunkSize, pool: self)
            free.append(c)
            all.append(c)
        }
    }

    func take() -> Chunk {
        semaphore.wait()
        lock.lock(); defer { lock.unlock() }
        return free.removeLast()
    }

    func give(_ chunk: Chunk) {
        lock.lock(); free.append(chunk); lock.unlock()
        semaphore.signal()
    }
}
