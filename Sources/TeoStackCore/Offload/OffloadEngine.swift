import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Motore di offload con certificazione.
///
/// Garanzie:
/// - la sorgente è aperta SOLO in lettura e letta UNA volta (hash XXH64 calcolato durante la copia);
/// - ogni destinazione riceve i dati in parallelo in un file temporaneo `*.teostackpart`;
/// - dopo la copia ogni file viene RILETTO dalla destinazione senza cache e il suo XXH64 confrontato con la sorgente;
/// - solo se coincide il file temporaneo viene rinominato col nome definitivo: un file con nome definitivo
///   creato da questo motore è quindi sempre verificato;
/// - non viene mai sovrascritto un file già presente in destinazione (viene solo verificato).
public final class OffloadEngine {
    public static let partialSuffix = ".teostackpart"

    public struct Configuration {
        public var chunkSize = 8 * 1024 * 1024
        public var bufferCount = 6
        public var verifyBufferSize = 8 * 1024 * 1024
        public var progressInterval: TimeInterval = 0.25
        public var rateWindow: TimeInterval = 5
        /// Margine di spazio libero richiesto oltre alla dimensione dei file.
        public var safetyMarginBytes: Int64 = 16 * 1024 * 1024
        public var freeSpaceProvider: (URL) -> Int64? = { DiskIO.availableSpace(atOrAbove: $0.path) }
        public var journalStore: JournalStore?
        public init() {}
    }

    public var onSnapshot: ((OffloadSnapshot) -> Void)?
    public var onFileUpdate: ((FileUpdate) -> Void)?
    public var onPhase: ((OffloadPhase) -> Void)?

    public let job: OffloadJob
    public let scan: ScanResult
    public let configuration: Configuration

    // MARK: Stato condiviso (protetto da `lock`)

    private let lock = NSLock()
    private var cancelFlag = false
    private var phase: OffloadPhase = .idle
    private var currentFile: String?
    private var results: [FileResult]
    private var deadReason: [String?]
    private var createdDirs: [[String]]
    private var partialPaths: [Set<String>]
    private var verifyItems: [[VerifyItem]]
    private var journalDirty = false

    private var readBytes: Int64 = 0
    private var filesCopied = 0
    private var writtenBytes: [Int64]
    private var verifiedBytes: [Int64]
    private var destTotals: [Int64]
    private var totalBytes: Int64 = 0
    private var skippedAlreadyVerified = 0

    private var readRate: RateWindow
    private var writeRates: [RateWindow]
    private var verifyRates: [RateWindow]
    private var startedAt = Date()
    private var timer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "teostack.offload.timer")
    private var lastJournalSave = Date.distantPast

    private let resumeHashes: [String: String]   // hash sorgente registrati in un tentativo precedente

    private struct VerifyItem {
        let fileIndex: Int
        let path: String
        let isPartial: Bool
    }

    public init(job: OffloadJob, scan: ScanResult, configuration: Configuration = Configuration(), resume: OffloadJournal? = nil) {
        self.job = job
        self.scan = scan
        self.configuration = configuration
        let n = job.destinationRoots.count
        let blank = DestFileResult()
        var initial = scan.files.map {
            FileResult(relativePath: $0.relativePath, size: $0.size, sourceHash: nil,
                       destinations: Array(repeating: blank, count: n))
        }
        var hashes: [String: String] = [:]
        if let resume, resume.job.destinationRoots.map({ $0.standardizedFileURL.path }) == job.destinationRoots.map({ $0.standardizedFileURL.path }) {
            let previous = Dictionary(resume.files.map { ($0.relativePath, $0) }, uniquingKeysWith: { a, _ in a })
            for i in initial.indices {
                guard let old = previous[initial[i].relativePath], old.size == initial[i].size,
                      old.destinations.count == n else { continue }
                if let h = old.sourceHash { hashes[initial[i].relativePath] = h }
                for d in 0..<n where old.destinations[d].status == .ok {
                    // Un OK precedente vale solo se il file definitivo esiste ancora con la stessa dimensione.
                    let path = job.destinationRoots[d].standardizedFileURL.path + "/" + initial[i].relativePath
                    if let st = try? DiskIO.lstatInfo(path: path), st.isRegular, st.size == initial[i].size {
                        initial[i].destinations[d] = old.destinations[d]
                        initial[i].sourceHash = old.sourceHash
                    }
                }
            }
        }
        results = initial
        resumeHashes = hashes
        deadReason = Array(repeating: nil, count: n)
        createdDirs = Array(repeating: [], count: n)
        partialPaths = Array(repeating: [], count: n)
        verifyItems = Array(repeating: [], count: n)
        writtenBytes = Array(repeating: 0, count: n)
        verifiedBytes = Array(repeating: 0, count: n)
        destTotals = Array(repeating: 0, count: n)
        readRate = RateWindow(window: configuration.rateWindow)
        writeRates = Array(repeating: RateWindow(window: configuration.rateWindow), count: n)
        verifyRates = Array(repeating: RateWindow(window: configuration.rateWindow), count: n)
    }

    // MARK: API

    public func cancel() {
        lock.lock(); cancelFlag = true; lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelFlag
    }

    /// Esegue l'offload (bloccante: chiamare da un thread in background).
    public func run() -> OffloadResult {
        startedAt = Date()
        setPhase(.preflight)
        let errors = preflight()
        if !errors.isEmpty {
            setPhase(.finished)
            return makeResult(.preflightFailed, preflightErrors: errors)
        }

        lock.lock()
        let n = job.destinationRoots.count
        for i in results.indices {
            var needsRead = false
            for d in 0..<n where results[i].destinations[d].status != .ok {
                destTotals[d] += results[i].size
                needsRead = true
            }
            if needsRead { totalBytes += results[i].size } else { skippedAlreadyVerified += 1 }
        }
        lock.unlock()

        startTimer()
        saveJournal(.running, force: true)

        setPhase(.copying)
        copyPhase()
        if !isCancelled {
            setPhase(.verifying)
            verifyPhase()
        }
        let cancelled = isCancelled
        if cancelled {
            cleanUpPartialFiles()
        } else {
            applyDirectoryDates()
        }
        stopTimer()
        setPhase(.finished)
        emitSnapshot(sampleRates: false)
        let result = makeResult(cancelled ? .cancelled : .completed, preflightErrors: [])
        saveJournal(cancelled ? .cancelled : .completed, force: true)
        return result
    }

    // MARK: Preflight

    private func preflight() -> [String] {
        var errors: [String] = []
        let n = job.destinationRoots.count
        if n < 1 || n > 3 { errors.append("Servono da 1 a 3 destinazioni (selezionate: \(n)).") }
        let source = job.sourceURL.standardizedFileURL.path
        var seen = Set<String>()
        for (d, url) in job.destinationRoots.enumerated() {
            let path = url.standardizedFileURL.path
            let label = "Destinazione \(d + 1)"
            if !seen.insert(path).inserted { errors.append("\(label): la stessa cartella è selezionata più volte.") }
            if path == source || path.hasPrefix(source + "/") {
                errors.append("\(label): si trova dentro la sorgente. La sorgente non deve mai essere modificata.")
                continue
            }
            let parent = (path as NSString).deletingLastPathComponent
            var isDir: ObjCBool = false
            let rootExists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            let parentExists = FileManager.default.fileExists(atPath: parent, isDirectory: &isDir)
            if !rootExists && !parentExists {
                errors.append("\(label): cartella non raggiungibile «\(path)» (disco scollegato?).")
                continue
            }
            if access(rootExists ? path : parent, W_OK) != 0 {
                errors.append("\(label): nessun permesso di scrittura su «\(rootExists ? path : parent)».")
                continue
            }
            var needed: Int64 = 0
            for f in results where f.destinations[d].status != .ok { needed += f.size }
            if let free = configuration.freeSpaceProvider(url) {
                if free < needed + configuration.safetyMarginBytes {
                    errors.append("\(label): spazio insufficiente. Servono \(Format.bytes(needed)), disponibili \(Format.bytes(free)).")
                }
            }
        }
        return errors
    }

    // MARK: Fase di copia

    private final class Target {
        let d: Int
        let finalPath: String
        let tempPath: String
        let fd: Int32
        let queue: DispatchQueue
        private let lock = NSLock()
        private var _error: DiskIOError?
        init(d: Int, finalPath: String, tempPath: String, fd: Int32) {
            self.d = d; self.finalPath = finalPath; self.tempPath = tempPath; self.fd = fd
            queue = DispatchQueue(label: "teostack.offload.writer.\(d)")
        }
        var error: DiskIOError? {
            get { lock.lock(); defer { lock.unlock() }; return _error }
            set { lock.lock(); _error = newValue; lock.unlock() }
        }
    }

    private func destPath(_ d: Int, _ relative: String) -> String {
        job.destinationRoots[d].standardizedFileURL.path + "/" + relative
    }

    private func copyPhase() {
        let pool = ChunkPool(chunkSize: configuration.chunkSize, count: configuration.bufferCount)
        for i in scan.files.indices {
            if isCancelled { return }
            copyFile(index: i, pool: pool)
        }
    }

    private func copyFile(index i: Int, pool: ChunkPool) {
        let file = scan.files[i]
        let n = job.destinationRoots.count
        var targets: [Target] = []
        var verifyOnly: [Int] = []

        for d in 0..<n {
            if getStatus(i, d) == .ok { continue }
            if let reason = deadReasonFor(d) {
                setStatus(i, d, .error, message: "Non copiato: destinazione in errore (\(reason))")
                continue
            }
            let finalPath = destPath(d, file.relativePath)
            let tempPath = finalPath + OffloadEngine.partialSuffix
            do {
                if let existing = try? DiskIO.lstatInfo(path: finalPath) {
                    guard existing.isRegular else {
                        setStatus(i, d, .error, message: "Esiste già un elemento con questo nome che non è un file: non viene toccato.")
                        continue
                    }
                    // Mai sovrascrivere: il file esistente verrà solo verificato.
                    queueVerification(d, VerifyItem(fileIndex: i, path: finalPath, isPartial: false))
                    setStatus(i, d, .copied, message: "File già presente in destinazione: non copiato, solo verificato")
                    continue
                }
                try ensureDirectory((finalPath as NSString).deletingLastPathComponent, destination: d)
                let fd = try DiskIO.openForWriting(path: tempPath)
                registerPartial(d, tempPath)
                targets.append(Target(d: d, finalPath: finalPath, tempPath: tempPath, fd: fd))
                setStatus(i, d, .copying)
            } catch let e as DiskIOError {
                fail(i, d, e)
            } catch {
                setStatus(i, d, .error, message: error.localizedDescription)
            }
        }
        verifyOnly = (0..<n).filter { d in getStatus(i, d) == .copied }
        if targets.isEmpty && verifyOnly.isEmpty { return }

        setCurrentFile(file.relativePath)
        let sourcePath = job.sourceURL.standardizedFileURL.path + "/" + file.relativePath

        func abort(_ message: String) {
            for t in targets {
                close(t.fd)
                removePartial(t.d, t.tempPath)
                setStatus(i, t.d, .error, message: message)
            }
            for d in verifyOnly {
                dropVerification(d, fileIndex: i)
                setStatus(i, d, .error, message: message)
            }
        }

        let srcFD: Int32
        do {
            srcFD = try DiskIO.openForReading(path: sourcePath, uncached: true)
        } catch {
            abort("Sorgente non leggibile: \(error)")
            return
        }

        let hasher = XXH64Hasher()
        var offset: Int64 = 0
        var readError: DiskIOError?
        var cancelledMidFile = false
        let group = DispatchGroup()

        while true {
            if isCancelled { cancelledMidFile = true; break }
            if !targets.isEmpty && verifyOnly.isEmpty && targets.allSatisfy({ $0.error != nil }) { break }
            let chunk = pool.take()
            let got: Int
            do {
                got = try DiskIO.readFully(fd: srcFD, into: chunk.buffer, count: configuration.chunkSize, path: sourcePath)
            } catch let e as DiskIOError {
                readError = e
                pool.give(chunk)
                break
            } catch {
                readError = DiskIOError(code: EIO, operation: "Lettura", path: sourcePath)
                pool.give(chunk)
                break
            }
            if got == 0 { pool.give(chunk); break }
            hasher.update(chunk.buffer, count: got)
            offset += Int64(got)
            addRead(got)
            DiskIO.dropCachedPages(fd: srcFD, offset: offset - Int64(got), length: got)
            chunk.count = got
            let live = targets.filter { $0.error == nil }
            if live.isEmpty {
                pool.give(chunk)
            } else {
                chunk.setReferences(live.count)
                for t in live {
                    t.queue.async(group: group) { [self] in
                        defer { chunk.release() }
                        if t.error != nil { return }
                        do {
                            try DiskIO.writeFully(fd: t.fd, from: chunk.buffer, count: chunk.count, path: t.tempPath)
                            addWritten(t.d, chunk.count)
                        } catch let e as DiskIOError {
                            t.error = e
                        } catch {
                            t.error = DiskIOError(code: EIO, operation: "Scrittura", path: t.tempPath)
                        }
                    }
                }
            }
            if got < configuration.chunkSize { break }
        }
        group.wait()
        close(srcFD)

        if cancelledMidFile {
            for t in targets { close(t.fd) }   // i file parziali vengono rimossi da cleanUpPartialFiles()
            for d in verifyOnly { dropVerification(d, fileIndex: i); setStatus(i, d, .pending) }
            for t in targets { setStatus(i, t.d, .pending) }
            return
        }
        if let readError {
            abort("Errore di lettura della sorgente: \(readError)")
            return
        }
        if targets.allSatisfy({ $0.error != nil }) && verifyOnly.isEmpty && !targets.isEmpty && offset != file.size {
            // Interrotto prima della fine perché tutte le destinazioni sono fallite: mostrare gli errori di scrittura.
        } else if offset != file.size {
            abort("La dimensione della sorgente è cambiata durante la lettura (attesi \(file.size) byte, letti \(offset)).")
            return
        }

        let sourceHash = hasher.hexDigest()
        let previousHash = resumeHashes[file.relativePath]
        if let previousHash, previousHash != sourceHash, offset == file.size {
            abort("La sorgente è cambiata rispetto al tentativo precedente (XXH64 diverso): file non copiato.")
            return
        }

        for t in targets {
            if let e = t.error {
                close(t.fd)
                removePartial(t.d, t.tempPath)
                fail(i, t.d, e)
                continue
            }
            do {
                try DiskIO.flushToDisk(fd: t.fd, path: t.tempPath)
                if close(t.fd) != 0 { throw DiskIOError(code: errno, operation: "Chiusura file", path: t.tempPath) }
                try DiskIO.applyTimes(DiskIO.FileTimes(modification: file.modificationDate, creation: file.creationDate),
                                      toPath: t.tempPath)
                queueVerification(t.d, VerifyItem(fileIndex: i, path: t.tempPath, isPartial: true))
                setStatus(i, t.d, .copied)
            } catch let e as DiskIOError {
                removePartial(t.d, t.tempPath)
                fail(i, t.d, e)
            } catch {
                removePartial(t.d, t.tempPath)
                setStatus(i, t.d, .error, message: error.localizedDescription)
            }
        }
        lock.lock()
        results[i].sourceHash = sourceHash
        filesCopied += 1
        journalDirty = true
        lock.unlock()
    }

    // MARK: Fase di verifica

    private func verifyPhase() {
        let group = DispatchGroup()
        for d in 0..<job.destinationRoots.count {
            DispatchQueue.global(qos: .userInitiated).async(group: group) { [self] in
                verifyDestination(d)
            }
        }
        group.wait()
    }

    private func verifyDestination(_ d: Int) {
        lock.lock()
        let items = verifyItems[d]
        lock.unlock()
        for item in items {
            if isCancelled { return }
            let i = item.fileIndex
            guard let sourceHash = sourceHashOf(i) else { continue }
            let size = scan.files[i].size
            setStatus(i, d, .verifying)
            setCurrentFile(scan.files[i].relativePath)
            do {
                let (hash, bytes) = try FileVerifier.hash(path: item.path, uncached: true,
                                                          bufferSize: configuration.verifyBufferSize,
                                                          isCancelled: { self.isCancelled },
                                                          onProgress: { self.addVerified(d, $0) })
                if bytes != size {
                    setStatus(i, d, .mismatch, message: "Dimensione riletta \(bytes) byte, attesa \(size) byte", hash: hash)
                } else if hash != sourceHash {
                    setStatus(i, d, .mismatch, message: "XXH64 destinazione \(hash) ≠ sorgente \(sourceHash)", hash: hash)
                } else if item.isPartial {
                    let finalPath = String(item.path.dropLast(OffloadEngine.partialSuffix.count))
                    if (try? DiskIO.lstatInfo(path: finalPath)) != nil {
                        setStatus(i, d, .error, message: "Un file con lo stesso nome è comparso durante l'offload: non sovrascritto.", hash: hash)
                    } else if rename(item.path, finalPath) != 0 {
                        fail(i, d, DiskIOError(code: errno, operation: "Rinomina file verificato", path: finalPath))
                    } else {
                        unregisterPartial(d, item.path)
                        setStatus(i, d, .ok, hash: hash)
                    }
                } else {
                    setStatus(i, d, .ok, hash: hash)
                }
            } catch is CancellationError {
                setStatus(i, d, .copied)
                return
            } catch let e as DiskIOError {
                setStatus(i, d, .error, message: "Rilettura per verifica fallita: \(e)")
            } catch {
                setStatus(i, d, .error, message: error.localizedDescription)
            }
        }
    }

    // MARK: Pulizia e date

    /// Rimuove SOLO i file `*.teostackpart` creati da questo motore e le cartelle create da questo motore (se vuote).
    private func cleanUpPartialFiles() {
        lock.lock()
        let partials = partialPaths
        let dirs = createdDirs
        lock.unlock()
        for d in partials.indices {
            for path in partials[d] where path.hasSuffix(OffloadEngine.partialSuffix) {
                unlink(path)
            }
            for dir in dirs[d].reversed() { rmdir(dir) }   // rmdir non rimuove cartelle non vuote
        }
        lock.lock()
        partialPaths = Array(repeating: [], count: partials.count)
        for i in results.indices {
            for d in results[i].destinations.indices {
                switch results[i].destinations[d].status {
                case .copying, .copied, .verifying, .mismatch:
                    results[i].destinations[d] = DestFileResult()
                default: break
                }
            }
        }
        lock.unlock()
    }

    private func applyDirectoryDates() {
        let dirs = scan.directories.sorted { $0.relativePath.count > $1.relativePath.count }
        for d in 0..<job.destinationRoots.count {
            for dir in dirs {
                let path = destPath(d, dir.relativePath)
                guard let st = try? DiskIO.lstatInfo(path: path), st.isDirectory else { continue }
                try? DiskIO.applyTimes(DiskIO.FileTimes(modification: dir.modificationDate, creation: dir.creationDate), toPath: path)
            }
        }
    }

    private func ensureDirectory(_ path: String, destination d: Int) throws {
        if let st = try? DiskIO.lstatInfo(path: path) {
            if st.isDirectory { return }
            throw DiskIOError(code: ENOTDIR, operation: "Creazione cartella", path: path)
        }
        let root = job.destinationRoots[d].standardizedFileURL.path
        let parent = (path as NSString).deletingLastPathComponent
        if path != root && parent != path { try ensureDirectory(parent, destination: d) }
        if mkdir(path, 0o755) != 0 && errno != EEXIST {
            throw DiskIOError(code: errno, operation: "Creazione cartella", path: path)
        }
        lock.lock(); createdDirs[d].append(path); lock.unlock()
    }

    // MARK: Stato

    private func getStatus(_ i: Int, _ d: Int) -> DestFileStatus {
        lock.lock(); defer { lock.unlock() }
        return results[i].destinations[d].status
    }

    private func sourceHashOf(_ i: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        return results[i].sourceHash
    }

    private func setStatus(_ i: Int, _ d: Int, _ status: DestFileStatus, message: String? = nil, hash: String? = nil) {
        lock.lock()
        results[i].destinations[d].status = status
        // Un messaggio informativo (es. "già presente") resta finché lo stato non regredisce o non arriva un nuovo messaggio.
        if message != nil || status == .pending || status == .copying {
            results[i].destinations[d].message = message
        }
        if let hash { results[i].destinations[d].destHash = hash }
        journalDirty = true
        lock.unlock()
        onFileUpdate?(FileUpdate(fileIndex: i, destinationIndex: d, status: status, message: message))
    }

    /// Errore di scrittura/creazione: segna il file e, se l'errore è grave, l'intera destinazione.
    private func fail(_ i: Int, _ d: Int, _ error: DiskIOError) {
        if error.isFatalForDestination {
            lock.lock()
            if deadReason[d] == nil { deadReason[d] = error.description }
            lock.unlock()
        }
        setStatus(i, d, .error, message: error.description)
    }

    private func deadReasonFor(_ d: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        return deadReason[d]
    }

    private func queueVerification(_ d: Int, _ item: VerifyItem) {
        lock.lock(); verifyItems[d].append(item); lock.unlock()
    }

    private func dropVerification(_ d: Int, fileIndex: Int) {
        lock.lock(); verifyItems[d].removeAll { $0.fileIndex == fileIndex }; lock.unlock()
    }

    private func registerPartial(_ d: Int, _ path: String) {
        lock.lock(); partialPaths[d].insert(path); lock.unlock()
    }

    private func unregisterPartial(_ d: Int, _ path: String) {
        lock.lock(); partialPaths[d].remove(path); lock.unlock()
    }

    private func removePartial(_ d: Int, _ path: String) {
        unlink(path)
        unregisterPartial(d, path)
    }

    private func setCurrentFile(_ name: String) {
        lock.lock(); currentFile = name; lock.unlock()
    }

    private func addRead(_ n: Int) {
        lock.lock(); readBytes += Int64(n); lock.unlock()
    }

    private func addWritten(_ d: Int, _ n: Int) {
        lock.lock(); writtenBytes[d] += Int64(n); lock.unlock()
    }

    private func addVerified(_ d: Int, _ n: Int) {
        lock.lock(); verifiedBytes[d] += Int64(n); lock.unlock()
    }

    private func setPhase(_ p: OffloadPhase) {
        lock.lock(); phase = p; lock.unlock()
        onPhase?(p)
    }

    // MARK: Avanzamento

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: timerQueue)
        t.schedule(deadline: .now() + configuration.progressInterval, repeating: configuration.progressInterval)
        t.setEventHandler { [weak self] in
            self?.emitSnapshot(sampleRates: true)
            self?.saveJournalIfDue()
        }
        timer = t
        t.resume()
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
        timerQueue.sync {}   // attende l'eventuale snapshot in corso
    }

    private func emitSnapshot(sampleRates: Bool) {
        guard let handler = onSnapshot else { return }
        handler(makeSnapshot(sampleRates: sampleRates))
    }

    private func makeSnapshot(sampleRates: Bool) -> OffloadSnapshot {
        lock.lock(); defer { lock.unlock() }
        let elapsed = Date().timeIntervalSince(startedAt)
        if sampleRates {
            readRate.add(time: elapsed, value: readBytes)
            for d in writeRates.indices {
                writeRates[d].add(time: elapsed, value: writtenBytes[d])
                verifyRates[d].add(time: elapsed, value: verifiedBytes[d])
            }
        }
        var snap = OffloadSnapshot()
        snap.phase = phase
        snap.currentFile = currentFile
        snap.totalBytes = totalBytes
        snap.readBytes = readBytes
        snap.readSpeed = phase == .copying ? readRate.rate : 0
        snap.filesTotal = results.count
        snap.filesCopied = filesCopied
        snap.elapsed = elapsed
        var etas: [TimeInterval?] = []
        for d in job.destinationRoots.indices {
            var p = DestinationProgress(root: job.destinationRoots[d])
            p.totalBytes = destTotals[d]
            p.writtenBytes = writtenBytes[d]
            p.verifiedBytes = verifiedBytes[d]
            p.writeSpeed = phase == .copying ? writeRates[d].rate : 0
            p.verifySpeed = phase == .verifying ? verifyRates[d].rate : 0
            p.fatalError = deadReason[d]
            for f in results {
                switch f.destinations[d].status {
                case .ok: p.okCount += 1
                case .mismatch: p.mismatchCount += 1
                case .error: p.errorCount += 1
                default: break
                }
            }
            switch phase {
            case .copying:
                let remaining = max(0, p.totalBytes - p.writtenBytes)
                p.eta = remaining == 0 ? 0 : (p.writeSpeed > 0 ? Double(remaining) / p.writeSpeed : nil)
            case .verifying:
                let remaining = max(0, p.totalBytes - p.verifiedBytes)
                p.eta = remaining == 0 ? 0 : (p.verifySpeed > 0 ? Double(remaining) / p.verifySpeed : nil)
            default:
                p.eta = 0
            }
            etas.append(p.eta)
            snap.destinations.append(p)
        }
        if etas.allSatisfy({ $0 != nil }) {
            snap.eta = etas.compactMap { $0 }.max() ?? 0
        }
        return snap
    }

    // MARK: Risultato e registro

    private func makeResult(_ outcome: OffloadOutcome, preflightErrors: [String]) -> OffloadResult {
        lock.lock(); defer { lock.unlock() }
        return OffloadResult(job: job, outcome: outcome, files: results, preflightErrors: preflightErrors,
                             destinationErrors: deadReason, skippedAlreadyVerified: skippedAlreadyVerified,
                             elapsed: Date().timeIntervalSince(startedAt))
    }

    private func saveJournalIfDue() {
        lock.lock()
        let due = journalDirty && Date().timeIntervalSince(lastJournalSave) > 2
        lock.unlock()
        if due { saveJournal(.running, force: false) }
    }

    private func saveJournal(_ state: OffloadJournal.State, force: Bool) {
        guard let store = configuration.journalStore else { return }
        lock.lock()
        let journal = OffloadJournal(job: job, state: state, files: results, updatedAt: Date())
        journalDirty = false
        lastJournalSave = Date()
        lock.unlock()
        try? store.save(journal)
    }
}

public enum Format {
    public static func bytes(_ value: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(value)
        var u = 0
        while v >= 1000 && u < units.count - 1 { v /= 1000; u += 1 }
        return u == 0 ? "\(value) B" : String(format: "%.2f %@", v, units[u])
    }

    public static func megabytesPerSecond(_ bytesPerSecond: Double) -> String {
        String(format: "%.0f MB/s", bytesPerSecond / 1_000_000)
    }

    public static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite else { return "—" }
        let s = Int(seconds.rounded())
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
