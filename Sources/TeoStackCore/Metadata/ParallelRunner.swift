import Foundation

/// Esegue un lavoro per ogni elemento con al massimo `limit` lavori contemporanei (pensato per lanciare programmi esterni come ExifTool,
/// art-cmd e ffmpeg, che passano quasi tutto il tempo in attesa). Ritorna quando tutti sono finiti.
/// Se un lavoro lancia un errore, quelli non ancora partiti vengono saltati e viene rilanciato il primo errore.
public enum ParallelRunner {
    /// Numero di lavori contemporanei consigliato: metà dei core, tra 2 e 4 (art-cmd usa già più thread per conto suo).
    public static var defaultLimit: Int { max(2, min(4, ProcessInfo.processInfo.activeProcessorCount / 2)) }

    public static func forEach<T>(_ items: [T], limit: Int = defaultLimit, _ body: (Int, T) throws -> Void) throws {
        if items.isEmpty { return }
        let workers = max(1, min(limit, items.count))
        if workers == 1 {
            for (i, item) in items.enumerated() { try body(i, item) }
            return
        }
        let lock = NSLock()
        var next = 0
        var firstError: Error?
        let group = DispatchGroup()
        withoutActuallyEscaping(body) { body in
            for _ in 0..<workers {
                DispatchQueue.global(qos: .utility).async(group: group) {
                    while true {
                        lock.lock()
                        if firstError != nil || next >= items.count { lock.unlock(); return }
                        let i = next
                        next += 1
                        lock.unlock()
                        do { try body(i, items[i]) } catch {
                            lock.lock(); if firstError == nil { firstError = error }; lock.unlock()
                        }
                    }
                }
            }
            group.wait()
        }
        if let firstError { throw firstError }
    }
}
