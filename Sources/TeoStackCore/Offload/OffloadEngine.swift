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
        /// La verifica di un file inizia appena è stato scritto, mentre la copia prosegue con i successivi (una rilettura per destinazione).
        /// Con false la verifica parte solo a copia finita (utile con dischi lenti che non reggono letture e scritture insieme).
        public var overlapVerification = Configuration.defaultOverlapVerification
        /// Valore iniziale di `overlapVerification` (modificabile dalle impostazioni dell'app e dai test).
        public static var defaultOverlapVerification = true
        /// I file più piccoli di questa soglia usano `fsync` e un solo svuotamento della cache del disco prima della verifica,
        /// invece di un F_FULLFSYNC per ogni file. 0 = F_FULLFSYNC per ogni file.
        public var deferredSyncThreshold: Int64 = 64 * 1024 * 1024
        /// Se presente, a offload riuscito su una destinazione si scrive la cartella `ascmhl` (ASC MHL 2.0) dentro la copia. nil = disattivato.
        public var ascMHL: ASCMHLOptions?
        /// Ogni quanti byte letti di un file grande si registra un punto di ripresa (dati sincronizzati su disco): se l'offload si interrompe
        /// (errore, scheda staccata, blocco, chiusura del programma) «Riprendi» continua da lì invece che da zero. 0 = nessun punto di ripresa.
        public var checkpointInterval: Int64 = 1 << 30
        /// Dopo quanti secondi senza risposta da disco o lettore si segnala un possibile blocco (`OffloadSnapshot.stall`).
        public var stallThreshold: TimeInterval = 15
        /// Solo per i test: chiamato dopo ogni blocco letto dalla sorgente (indice del file, byte letti finora).
        public var afterChunk: ((Int, Int64) -> Void)?
        /// Solo per i test: chiamato dentro ogni scrittura su una destinazione (indice della destinazione), per simulare un disco lento o bloccato.
        public var duringWrite: ((Int) -> Void)?
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
    private var verifyCursor: [Int]
    private var copyFinished = false
    private var unflushed: [Bool]
    private var lastUnflushedPath: [String?]
    private let verifySignals: [DispatchSemaphore]
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
    private let resumeCheckpoints: [String: CopyCheckpoint]   // punti di ripresa di un tentativo precedente (file con sorgente invariata)
    private let sourceUnchanged: Set<String>     // file la cui sorgente ha ancora dimensione e data del tentativo precedente

    // Pausa, sospensione e controllo dei blocchi
    private let pauseCondition = NSCondition()
    private var pauseFlag = false
    private var pausedSince: Date?
    private var pausedTotal: TimeInterval = 0
    private var suspendFlag = false
    private enum Activity: Hashable { case readSource, writeDest(Int), verifyDest(Int) }
    private var activities: [Activity: Date] = [:]

    private struct VerifyItem {
        let fileIndex: Int
        let path: String
        let isPartial: Bool
        var needsDeviceFlush = false
    }

    public init(job: OffloadJob, scan: ScanResult, configuration: Configuration = Configuration(), resume: OffloadJournal? = nil) {
        self.job = job
        self.scan = scan
        self.configuration = configuration
        let n = job.destinationRoots.count
        let blank = DestFileResult()
        var initial = scan.files.map {
            FileResult(relativePath: $0.relativePath, size: $0.size, sourceHash: nil,
                       destinations: Array(repeating: blank, count: n), modificationDate: $0.modificationDate)
        }
        var hashes: [String: String] = [:]
        var checkpoints: [String: CopyCheckpoint] = [:]
        var unchanged = Set<String>()
        if let resume, resume.job.destinationRoots.map({ $0.standardizedFileURL.path }) == job.destinationRoots.map({ $0.standardizedFileURL.path }) {
            let previous = Dictionary(resume.files.map { ($0.relativePath, $0) }, uniquingKeysWith: { a, _ in a })
            for i in initial.indices {
                guard let old = previous[initial[i].relativePath], old.size == initial[i].size,
                      old.destinations.count == n else { continue }
                // Il registro salva le date al secondo: si accetta una differenza minore di un secondo.
                if let a = old.modificationDate, let b = initial[i].modificationDate, abs(a.timeIntervalSince(b)) < 1 {
                    unchanged.insert(initial[i].relativePath)
                    if let cp = old.checkpoint { checkpoints[initial[i].relativePath] = cp }
                }
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
        resumeCheckpoints = checkpoints
        sourceUnchanged = unchanged
        deadReason = Array(repeating: nil, count: n)
        createdDirs = Array(repeating: [], count: n)
        partialPaths = Array(repeating: [], count: n)
        verifyItems = Array(repeating: [], count: n)
        verifyCursor = Array(repeating: 0, count: n)
        unflushed = Array(repeating: false, count: n)
        lastUnflushedPath = Array(repeating: nil, count: n)
        verifySignals = (0..<n).map { _ in DispatchSemaphore(value: 0) }
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
        wakePausedThreads()
    }

    /// Interrompe l'offload CONSERVANDO i file parziali e il punto di ripresa (per «Riprendi» più tardi, anche dopo aver chiuso il programma).
    /// A differenza di `cancel()` non rimuove nulla dalle destinazioni.
    public func suspend() {
        lock.lock(); suspendFlag = true; cancelFlag = true; lock.unlock()
        wakePausedThreads()
    }

    private var isSuspended: Bool {
        lock.lock(); defer { lock.unlock() }
        return suspendFlag
    }

    /// Mette in pausa: la lettura, la scrittura e la verifica si fermano al prossimo blocco (pochi MB) e restano ferme finché non si chiama `resume()`.
    /// Dischi e file restano aperti: si continua esattamente da dove ci si è fermati.
    public func pause() {
        lock.lock()
        if !pauseFlag { pauseFlag = true; pausedSince = Date() }
        lock.unlock()
    }

    public func resume() {
        lock.lock()
        if pauseFlag {
            pauseFlag = false
            if let since = pausedSince { pausedTotal += Date().timeIntervalSince(since) }
            pausedSince = nil
            // le operazioni in corso ripartono ora: il tempo di pausa non conta come blocco
            let now = Date()
            for key in activities.keys { activities[key] = now }
        }
        lock.unlock()
        wakePausedThreads()
    }

    public var isPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return pauseFlag
    }

    private func wakePausedThreads() {
        pauseCondition.lock(); pauseCondition.broadcast(); pauseCondition.unlock()
    }

    /// Si ferma qui finché l'offload è in pausa (esce subito se annullato o sospeso).
    private func waitIfPaused() {
        pauseCondition.lock()
        while isPaused && !isCancelled { pauseCondition.wait(until: Date().addingTimeInterval(0.5)) }
        pauseCondition.unlock()
    }

    // Controllo dei blocchi: si ricorda da quando è in corso ogni operazione su disco.
    private func beginActivity(_ a: Activity) { lock.lock(); activities[a] = Date(); lock.unlock() }
    private func touchActivity(_ a: Activity) { lock.lock(); if activities[a] != nil { activities[a] = Date() }; lock.unlock() }
    private func endActivity(_ a: Activity) { lock.lock(); activities[a] = nil; lock.unlock() }

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
        let verifiers = DispatchGroup()
        if configuration.overlapVerification { startVerifiers(in: verifiers) }
        copyPhase()
        lock.lock(); copyFinished = true; lock.unlock()
        verifySignals.forEach { $0.signal() }
        if !isCancelled { setPhase(.verifying) }
        if !configuration.overlapVerification && !isCancelled { startVerifiers(in: verifiers) }
        verifiers.wait()
        let cancelled = isCancelled
        var mhl: [ASCMHLOutcome?] = []
        if cancelled {
            // Sospeso: i file parziali e i punti di ripresa restano per «Riprendi». Annullato: si toglie ogni traccia.
            if !isSuspended { cleanUpPartialFiles() }
        } else {
            applyDirectoryDates()
            if let options = configuration.ascMHL {
                setPhase(.certifying)
                mhl = writeASCMHL(options)
            }
        }
        stopTimer()
        setPhase(.finished)
        emitSnapshot(sampleRates: false)
        var result = makeResult(cancelled ? .cancelled : .completed, preflightErrors: [])
        result.mhl = mhl
        saveJournal(cancelled ? .cancelled : .completed, force: true)
        return result
    }

    // MARK: Preflight

    private func preflight() -> [String] {
        var errors: [String] = []
        let n = job.destinationRoots.count
        if n < 1 || n > OffloadJob.maxDestinations {
            errors.append(tr("Servono da 1 a {0} destinazioni (selezionate: {1}).", OffloadJob.maxDestinations, n))
        }
        let source = job.sourceURL.standardizedFileURL.path
        var seen = Set<String>()
        for (d, url) in job.destinationRoots.enumerated() {
            let path = url.standardizedFileURL.path
            let label = tr("Destinazione {0}", d + 1)
            if !seen.insert(path).inserted { errors.append(tr("{0}: la stessa cartella è selezionata più volte.", label)) }
            if path == source || path.hasPrefix(source + "/") {
                errors.append(tr("{0}: si trova dentro la sorgente. La sorgente non deve mai essere modificata.", label))
                continue
            }
            var isDir: ObjCBool = false
            let writableAnchor: String       // cartella esistente su cui devo poter scrivere
            if let bases = job.destinationBases, d < bases.count {
                let basePath = bases[d].standardizedFileURL.path
                guard FileManager.default.fileExists(atPath: basePath, isDirectory: &isDir), isDir.boolValue else {
                    errors.append(tr("{0}: la cartella base «{1}» non è raggiungibile (disco scollegato?).", label, basePath))
                    continue
                }
                if !(path == basePath || path.hasPrefix(basePath + "/")) {
                    errors.append(tr("{0}: la cartella di destinazione non si trova dentro la cartella base scelta.", label))
                    continue
                }
                // la parte esistente più profonda del percorso (tra la base e la destinazione)
                var anchor = path
                while anchor != basePath && !FileManager.default.fileExists(atPath: anchor) {
                    anchor = (anchor as NSString).deletingLastPathComponent
                }
                writableAnchor = anchor
            } else {
                let parent = (path as NSString).deletingLastPathComponent
                let rootExists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                let parentExists = FileManager.default.fileExists(atPath: parent, isDirectory: &isDir)
                if !rootExists && !parentExists {
                    errors.append(tr("{0}: cartella non raggiungibile «{1}» (disco scollegato?).", label, path))
                    continue
                }
                writableAnchor = rootExists ? path : parent
            }
            if access(writableAnchor, W_OK) != 0 {
                errors.append(tr("{0}: nessun permesso di scrittura su «{1}».", label, writableAnchor))
                continue
            }
            var needed: Int64 = 0
            for f in results where f.destinations[d].status != .ok { needed += f.size }
            if let free = configuration.freeSpaceProvider(url) {
                if free < needed + configuration.safetyMarginBytes {
                    errors.append(tr("{0}: spazio insufficiente. Servono {1}, disponibili {2}.", label, Format.bytes(needed), Format.bytes(free)))
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
            waitIfPaused()
            if isCancelled { return }
            copyFile(index: i, pool: pool)
        }
    }

    private func copyFile(index i: Int, pool: ChunkPool) {
        let file = scan.files[i]
        let n = job.destinationRoots.count
        var targets: [Target] = []
        var verifyOnly: [Int] = []       // il file definitivo esiste già: solo verificato
        var partialVerify: [Int] = []    // ripresa: la copia parziale è già completa, solo da verificare
        var needsCopy: [Int] = []        // destinazioni da scrivere (da zero o riprendendo da un punto di ripresa)

        for d in 0..<n {
            if getStatus(i, d) == .ok { continue }
            if let reason = deadReasonFor(d) {
                setStatus(i, d, .error, message: tr("Non copiato: destinazione in errore ({0})", reason))
                continue
            }
            let finalPath = destPath(d, file.relativePath)
            let tempPath = finalPath + OffloadEngine.partialSuffix
            do {
                if let existing = try? DiskIO.lstatInfo(path: finalPath) {
                    guard existing.isRegular else {
                        setStatus(i, d, .error, message: tr("Esiste già un elemento con questo nome che non è un file: non viene toccato."))
                        continue
                    }
                    // Mai sovrascrivere: il file esistente verrà solo verificato (dopo aver letto la sorgente e calcolato il suo hash).
                    setStatus(i, d, .copied, message: tr("File già presente in destinazione: non copiato, solo verificato"))
                    continue
                }
                if hasCompletePartial(i, tempPath) {
                    // Ripresa: la copia era già finita, mancava la verifica. Si verifica, non si ricopia.
                    partialVerify.append(d)
                    registerPartial(d, tempPath)
                    setStatus(i, d, .copied, message: tr("Ripresa: copia già completa, solo verificata"))
                    continue
                }
                try ensureDirectory((finalPath as NSString).deletingLastPathComponent, destination: d)
                needsCopy.append(d)
            } catch let e as DiskIOError {
                fail(i, d, e)
            } catch {
                setStatus(i, d, .error, message: error.localizedDescription)
            }
        }
        verifyOnly = (0..<n).filter { d in getStatus(i, d) == .copied && !partialVerify.contains(d) }

        // Tutto ciò che serve è già scritto e il suo hash è noto (stessa sorgente del tentativo precedente): non occorre rileggere la sorgente.
        if needsCopy.isEmpty && verifyOnly.isEmpty && !partialVerify.isEmpty, let known = resumeHashes[file.relativePath],
           sourceUnchanged.contains(file.relativePath) {
            setCurrentFile(file.relativePath)
            lock.lock()
            results[i].sourceHash = known
            results[i].checkpoint = nil
            filesCopied += 1
            journalDirty = true
            lock.unlock()
            creditProgress(read: file.size, written: partialVerify.map { ($0, file.size) })
            for d in partialVerify {
                queueVerification(d, VerifyItem(fileIndex: i, path: destPath(d, file.relativePath) + OffloadEngine.partialSuffix, isPartial: true))
            }
            return
        }

        // Punto di ripresa: la parte già scritta viene riletta dal disco e confrontata con l'hash registrato; solo se coincide si continua da lì.
        var resumePoint: CopyCheckpoint?
        if !needsCopy.isEmpty {
            switch validResumePoint(i, destinations: needsCopy) {
            case .cancelled: return
            case .none: break
            case .valid(let cp): resumePoint = cp
            }
        }

        for d in needsCopy {
            let tempPath = destPath(d, file.relativePath) + OffloadEngine.partialSuffix
            do {
                beginActivity(.writeDest(d))
                defer { endActivity(.writeDest(d)) }
                let fd: Int32
                if let resumePoint {
                    fd = try DiskIO.openForResuming(path: tempPath, at: resumePoint.offset)
                } else {
                    fd = try DiskIO.openForWriting(path: tempPath)
                }
                registerPartial(d, tempPath)
                targets.append(Target(d: d, finalPath: destPath(d, file.relativePath), tempPath: tempPath, fd: fd))
                setStatus(i, d, .copying)
            } catch let e as DiskIOError {
                fail(i, d, e)
            } catch {
                setStatus(i, d, .error, message: error.localizedDescription)
            }
        }
        if targets.isEmpty && verifyOnly.isEmpty && partialVerify.isEmpty { return }
        // Se non tutte le destinazioni da scrivere si sono aperte, un punto di ripresa vale comunque per quelle aperte (stesso offset).

        setCurrentFile(file.relativePath)
        let sourcePath = job.sourceURL.standardizedFileURL.path + "/" + file.relativePath

        /// `keepPartial`: la copia parziale e il suo punto di ripresa restano per «Riprendi» (solo se esiste un punto di ripresa valido).
        func abort(_ message: String, keepPartial: Bool = false) {
            let keep = keepPartial && hasCheckpoint(i)
            for t in targets {
                close(t.fd)
                if !keep { removePartial(t.d, t.tempPath) }
                setStatus(i, t.d, .error, message: message)
            }
            if !keep { clearCheckpoint(i) }
            for d in verifyOnly { setStatus(i, d, .error, message: message) }
            for d in partialVerify { setStatus(i, d, .error, message: message) }
        }

        let srcFD: Int32
        do {
            beginActivity(.readSource)
            defer { endActivity(.readSource) }
            srcFD = try DiskIO.openForReading(path: sourcePath, uncached: true)
        } catch {
            abort(tr("Sorgente non leggibile: {0}", error), keepPartial: true)
            return
        }

        let hasher = XXH64Hasher()
        var offset: Int64 = 0
        if let resumePoint {
            if hasher.restore(resumePoint.hashState), lseek(srcFD, off_t(resumePoint.offset), SEEK_SET) == off_t(resumePoint.offset) {
                offset = resumePoint.offset
                creditProgress(read: offset, written: targets.map { ($0.d, offset) })
            } else {
                close(srcFD)
                abort(tr("Impossibile riprendere la copia da metà file: il file riparte da zero al prossimo tentativo."))
                return
            }
        }
        var lastCheckpoint = offset
        var readError: DiskIOError?
        var cancelledMidFile = false
        let group = DispatchGroup()

        while true {
            waitIfPaused()
            if isCancelled { cancelledMidFile = true; break }
            if !targets.isEmpty && verifyOnly.isEmpty && partialVerify.isEmpty && targets.allSatisfy({ $0.error != nil }) { break }
            let chunk = pool.take()
            let got: Int
            do {
                beginActivity(.readSource)
                defer { endActivity(.readSource) }
                got = try DiskIO.readFully(fd: srcFD, into: chunk.buffer, count: configuration.chunkSize, path: sourcePath)
            } catch let e as DiskIOError {
                readError = e
                pool.give(chunk)
                break
            } catch {
                readError = DiskIOError(code: EIO, operation: tr("Lettura"), path: sourcePath)
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
                            beginActivity(.writeDest(t.d))
                            defer { endActivity(.writeDest(t.d)) }
                            configuration.duringWrite?(t.d)
                            try DiskIO.writeFully(fd: t.fd, from: chunk.buffer, count: chunk.count, path: t.tempPath)
                            addWritten(t.d, chunk.count)
                        } catch let e as DiskIOError {
                            t.error = e
                        } catch {
                            t.error = DiskIOError(code: EIO, operation: tr("Scrittura"), path: t.tempPath)
                        }
                    }
                }
            }
            configuration.afterChunk?(i, offset)
            // Punto di ripresa: tutti i dati scritti finora sono sul disco e il loro hash è registrato.
            if configuration.checkpointInterval > 0, !targets.isEmpty, offset < file.size,
               offset - lastCheckpoint >= configuration.checkpointInterval {
                group.wait()
                if recordCheckpoint(i, targets: targets, hasher: hasher, offset: offset) { lastCheckpoint = offset }
            }
            if got < configuration.chunkSize { break }
        }
        group.wait()
        close(srcFD)

        if cancelledMidFile {
            // Sospeso (non annullato): si registra l'ultimo punto di ripresa e i file parziali restano.
            let keep = isSuspended && !targets.isEmpty && offset > 0 && offset < file.size
                && recordCheckpoint(i, targets: targets, hasher: hasher, offset: offset)
            for t in targets {
                close(t.fd)
                if !keep { removePartial(t.d, t.tempPath) }
            }
            if !keep { clearCheckpoint(i) }
            for d in verifyOnly { setStatus(i, d, .pending) }
            for d in partialVerify { setStatus(i, d, .copied) }   // la copia parziale completa resta: alla ripresa si verifica soltanto
            for t in targets { setStatus(i, t.d, .pending) }
            return
        }
        if let readError {
            abort(tr("Errore di lettura della sorgente: {0}", readError), keepPartial: true)
            return
        }
        if targets.allSatisfy({ $0.error != nil }) && verifyOnly.isEmpty && partialVerify.isEmpty && !targets.isEmpty && offset != file.size {
            // Interrotto prima della fine perché tutte le destinazioni sono fallite: mostrare gli errori di scrittura.
        } else if offset != file.size {
            abort(tr("La dimensione della sorgente è cambiata durante la lettura (attesi {0} byte, letti {1}).", file.size, offset))
            return
        }

        let sourceHash = hasher.hexDigest()
        let previousHash = resumeHashes[file.relativePath]
        if let previousHash, previousHash != sourceHash, offset == file.size {
            abort(tr("La sorgente è cambiata rispetto al tentativo precedente (XXH64 diverso): file non copiato."))
            return
        }

        // L'hash della sorgente deve essere noto PRIMA di mettere i file in coda di verifica (la verifica può partire subito).
        lock.lock()
        results[i].sourceHash = sourceHash
        filesCopied += 1
        journalDirty = true
        lock.unlock()

        for d in verifyOnly { queueVerification(d, VerifyItem(fileIndex: i, path: destPath(d, file.relativePath), isPartial: false)) }
        for d in partialVerify {
            creditProgress(read: 0, written: [(d, file.size)])
            queueVerification(d, VerifyItem(fileIndex: i, path: destPath(d, file.relativePath) + OffloadEngine.partialSuffix, isPartial: true))
        }

        let deferSync = file.size < configuration.deferredSyncThreshold
        var keptForResume = false
        for t in targets {
            if let e = t.error {
                close(t.fd)
                // Errore di scrittura su questa destinazione: se c'è un punto di ripresa la copia parziale resta (disco pieno liberato, disco ricollegato…).
                if hasCheckpoint(i) { keptForResume = true } else { removePartial(t.d, t.tempPath) }
                fail(i, t.d, e)
                continue
            }
            do {
                beginActivity(.writeDest(t.d))
                defer { endActivity(.writeDest(t.d)) }
                if deferSync { try DiskIO.syncData(fd: t.fd, path: t.tempPath) } else { try DiskIO.flushToDisk(fd: t.fd, path: t.tempPath) }
                if close(t.fd) != 0 { throw DiskIOError(code: errno, operation: tr("Chiusura file"), path: t.tempPath) }
                try DiskIO.applyTimes(DiskIO.FileTimes(modification: file.modificationDate, creation: file.creationDate),
                                      toPath: t.tempPath)
                if deferSync { markUnflushed(t.d, path: t.tempPath) }
                setStatus(i, t.d, .copied)
                queueVerification(t.d, VerifyItem(fileIndex: i, path: t.tempPath, isPartial: true, needsDeviceFlush: deferSync))
            } catch let e as DiskIOError {
                removePartial(t.d, t.tempPath)
                fail(i, t.d, e)
            } catch {
                removePartial(t.d, t.tempPath)
                setStatus(i, t.d, .error, message: error.localizedDescription)
            }
        }
        // File concluso su tutte le destinazioni: il punto di ripresa non serve più (resta solo se una copia parziale è conservata per «Riprendi»).
        if !keptForResume { clearCheckpoint(i) }
    }

    // MARK: Ripresa da metà file

    private enum ResumeDecision { case valid(CopyCheckpoint), none, cancelled }

    /// Una copia parziale con la dimensione completa del file e un hash sorgente già noto (stessa sorgente): resta solo da verificare.
    private func hasCompletePartial(_ i: Int, _ tempPath: String) -> Bool {
        let file = scan.files[i]
        guard resumeHashes[file.relativePath] != nil, sourceUnchanged.contains(file.relativePath),
              let st = try? DiskIO.lstatInfo(path: tempPath), st.isRegular, st.size == file.size else { return false }
        return true
    }

    /// Controlla che il punto di ripresa registrato sia ancora buono su OGNI destinazione da scrivere: sorgente invariata, file parziali presenti e lunghi
    /// almeno `offset`, e — soprattutto — i primi `offset` byte riletti dal disco hanno l'XXH64 registrato. Altrimenti il file riparte da zero.
    private func validResumePoint(_ i: Int, destinations: [Int]) -> ResumeDecision {
        let file = scan.files[i]
        guard let cp = resumeCheckpoints[file.relativePath], cp.offset > 0, cp.offset < file.size,
              sourceUnchanged.contains(file.relativePath) else { return .none }
        // la parte di stato salvata deve riprodurre l'hash registrato
        let probe = XXH64Hasher()
        guard probe.restore(cp.hashState), probe.hexDigest() == cp.prefixHash else { return .none }
        var paths: [Int: String] = [:]
        for d in destinations {
            let path = destPath(d, file.relativePath) + OffloadEngine.partialSuffix
            guard let st = try? DiskIO.lstatInfo(path: path), st.isRegular, st.size >= cp.offset else { return .none }
            paths[d] = path
        }
        for d in destinations {
            setStatus(i, d, .copying, message: tr("Ripresa: ricontrollo la parte già copiata ({0})", Format.bytes(cp.offset)))
        }
        setCurrentFile(file.relativePath)
        let outcomes = Outcomes(count: destinations.count)
        DispatchQueue.concurrentPerform(iterations: destinations.count) { k in
            let d = destinations[k]
            beginActivity(.verifyDest(d))
            defer { endActivity(.verifyDest(d)) }
            do {
                let (hash, bytes) = try FileVerifier.hash(path: paths[d]!, uncached: true, bufferSize: configuration.verifyBufferSize, limit: cp.offset,
                                                          isCancelled: { self.waitIfPaused(); return self.isCancelled },
                                                          onProgress: { _ in self.touchActivity(.verifyDest(d)) })
                outcomes.set(k, bytes == cp.offset && hash == cp.prefixHash ? .good : .bad)
            } catch is CancellationError {
                outcomes.set(k, .cancelled)
            } catch {
                outcomes.set(k, .bad)
            }
        }
        if outcomes.contains(.cancelled) {
            for d in destinations { setStatus(i, d, .pending) }
            return .cancelled
        }
        guard outcomes.all(.good) else {
            for d in destinations { setStatus(i, d, .pending, message: nil) }
            return .none
        }
        return .valid(cp)
    }

    private final class Outcomes {
        enum Value { case unset, good, bad, cancelled }
        private var values: [Value]
        private let lock = NSLock()
        init(count: Int) { values = Array(repeating: .unset, count: count) }
        func set(_ k: Int, _ v: Value) { lock.lock(); values[k] = v; lock.unlock() }
        func contains(_ v: Value) -> Bool { lock.lock(); defer { lock.unlock() }; return values.contains(v) }
        func all(_ v: Value) -> Bool { lock.lock(); defer { lock.unlock() }; return values.allSatisfy { $0 == v } }
    }

    /// Registra un punto di ripresa: dati già scritti sincronizzati su ogni destinazione viva, stato dell'hash e hash dei primi `offset` byte.
    /// Chiamare solo con tutte le scritture accodate già concluse (`group.wait()`).
    private func recordCheckpoint(_ i: Int, targets: [Target], hasher: XXH64Hasher, offset: Int64) -> Bool {
        let live = targets.filter { $0.error == nil }
        guard !live.isEmpty, let state = hasher.exportState() else { return false }
        for t in live {
            beginActivity(.writeDest(t.d))
            defer { endActivity(.writeDest(t.d)) }
            do { try DiskIO.flushToDisk(fd: t.fd, path: t.tempPath) } catch let e as DiskIOError {
                t.error = e
                return false
            } catch {
                t.error = DiskIOError(code: EIO, operation: tr("Sincronizzazione su disco"), path: t.tempPath)
                return false
            }
        }
        let checkpoint = CopyCheckpoint(offset: offset, hashState: state, prefixHash: hasher.hexDigest())
        lock.lock()
        results[i].checkpoint = checkpoint
        journalDirty = true
        lock.unlock()
        saveJournal(.running, force: true)
        return true
    }

    private func hasCheckpoint(_ i: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return results[i].checkpoint != nil
    }

    private func clearCheckpoint(_ i: Int) {
        lock.lock()
        if results[i].checkpoint != nil { results[i].checkpoint = nil; journalDirty = true }
        lock.unlock()
    }

    /// Conta come già fatti i byte che una ripresa non rilegge/riscrive, senza falsare le velocità (le medie mobili ripartono da qui).
    private func creditProgress(read: Int64, written: [(Int, Int64)]) {
        lock.lock()
        let elapsed = Date().timeIntervalSince(startedAt) - pausedTotal
        if read > 0 {
            readBytes += read
            readRate = RateWindow(window: configuration.rateWindow)
            readRate.add(time: elapsed, value: readBytes)
        }
        for (d, bytes) in written where bytes > 0 {
            writtenBytes[d] += bytes
            writeRates[d] = RateWindow(window: configuration.rateWindow)
            writeRates[d].add(time: elapsed, value: writtenBytes[d])
        }
        lock.unlock()
    }

    // MARK: Fase di verifica

    /// Un lavoratore per destinazione: rilegge i file man mano che vengono messi in coda e termina a copia finita e coda vuota.
    private func startVerifiers(in group: DispatchGroup) {
        for d in 0..<job.destinationRoots.count {
            DispatchQueue.global(qos: .userInitiated).async(group: group) { [self] in
                verifyDestination(d)
            }
        }
    }

    private func nextVerifyItem(_ d: Int) -> (item: VerifyItem?, finished: Bool) {
        lock.lock(); defer { lock.unlock() }
        if verifyCursor[d] < verifyItems[d].count {
            verifyCursor[d] += 1
            return (verifyItems[d][verifyCursor[d] - 1], copyFinished)
        }
        return (nil, copyFinished)
    }

    private func markUnflushed(_ d: Int, path: String) {
        lock.lock(); unflushed[d] = true; lastUnflushedPath[d] = path; lock.unlock()
    }

    /// Prima di rileggere un file scritto solo con fsync: un unico svuotamento della cache del disco copre tutti i file scritti fino a quel momento.
    private func flushDeviceCacheIfNeeded(_ d: Int) throws {
        lock.lock()
        let path = unflushed[d] ? lastUnflushedPath[d] : nil
        unflushed[d] = false
        lock.unlock()
        if let path { try DiskIO.flushDeviceCache(path: path) }
    }

    private func verifyDestination(_ d: Int) {
        while true {
            waitIfPaused()
            if isCancelled { return }
            let next = nextVerifyItem(d)
            guard let item = next.item else {
                if next.finished { return }
                _ = verifySignals[d].wait(timeout: .now() + 0.2)
                continue
            }
            let i = item.fileIndex
            guard let sourceHash = sourceHashOf(i) else { continue }
            let size = scan.files[i].size
            setStatus(i, d, .verifying)
            if currentPhase == .verifying { setCurrentFile(scan.files[i].relativePath) }
            beginActivity(.verifyDest(d))
            defer { endActivity(.verifyDest(d)) }
            do {
                if item.needsDeviceFlush { try flushDeviceCacheIfNeeded(d) }
                let (hash, bytes) = try FileVerifier.hash(path: item.path, uncached: true,
                                                          bufferSize: configuration.verifyBufferSize,
                                                          isCancelled: { self.waitIfPaused(); return self.isCancelled },
                                                          onProgress: { self.addVerified(d, $0); self.touchActivity(.verifyDest(d)) })
                if bytes != size {
                    setStatus(i, d, .mismatch, message: tr("Dimensione riletta {0} byte, attesa {1} byte", bytes, size), hash: hash)
                } else if hash != sourceHash {
                    setStatus(i, d, .mismatch, message: tr("XXH64 destinazione {0} ≠ sorgente {1}", hash, sourceHash), hash: hash)
                } else if item.isPartial {
                    let finalPath = String(item.path.dropLast(OffloadEngine.partialSuffix.count))
                    if (try? DiskIO.lstatInfo(path: finalPath)) != nil {
                        setStatus(i, d, .error, message: tr("Un file con lo stesso nome è comparso durante l'offload: non sovrascritto."), hash: hash)
                    } else if rename(item.path, finalPath) != 0 {
                        fail(i, d, DiskIOError(code: errno, operation: tr("Rinomina file verificato"), path: finalPath))
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
                setStatus(i, d, .error, message: tr("Rilettura per verifica fallita: {0}", e))
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
            results[i].checkpoint = nil
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

    /// Scrive la cartella `ascmhl` su ogni destinazione i cui file sono TUTTI verificati OK (un certificato non deve attestare ciò che non è verificato).
    private func writeASCMHL(_ options: ASCMHLOptions) -> [ASCMHLOutcome?] {
        lock.lock()
        let snapshot = results
        let dead = deadReason
        lock.unlock()
        var outcomes: [ASCMHLOutcome?] = []
        for d in 0..<job.destinationRoots.count {
            if dead[d] != nil {
                outcomes.append(.skipped(tr("Destinazione con errore")))
                continue
            }
            guard !snapshot.isEmpty, snapshot.allSatisfy({ d < $0.destinations.count && $0.destinations[d].status == .ok }) else {
                outcomes.append(.skipped(tr("Non tutti i file sono verificati OK")))
                continue
            }
            var hashes: [String: String] = [:]
            for file in snapshot { if let h = file.sourceHash { hashes[file.relativePath] = h } }
            do {
                let written = try ASCMHLWriter.write(root: job.destinationRoots[d], knownHashes: hashes, options: options, isCancelled: { self.isCancelled })
                outcomes.append(.written(folder: ASCMHLWriter.folderName, file: written.file.lastPathComponent,
                                         generation: written.generation, files: written.fileCount))
            } catch {
                outcomes.append(.failed(String(describing: error)))
            }
        }
        return outcomes
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

    /// Cartella che deve esistere sempre durante l'offload: la base scelta dall'utente (o, senza base, la cartella che contiene la destinazione).
    /// Se sparisce il disco è stato scollegato: non si ricrea mai il suo percorso sul disco di avvio.
    private func destinationAnchor(_ d: Int) -> String {
        if let bases = job.destinationBases, d < bases.count { return bases[d].standardizedFileURL.path }
        return (job.destinationRoots[d].standardizedFileURL.path as NSString).deletingLastPathComponent
    }

    private func ensureDirectory(_ path: String, destination d: Int) throws {
        let anchor = destinationAnchor(d)
        var anchorIsDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: anchor, isDirectory: &anchorIsDir), anchorIsDir.boolValue else {
            throw DiskIOError(code: ENODEV, operation: tr("Destinazione non raggiungibile"), path: anchor)
        }
        try createDirectories(path, destination: d)
    }

    private func createDirectories(_ path: String, destination d: Int) throws {
        if let st = try? DiskIO.lstatInfo(path: path) {
            if st.isDirectory { return }
            throw DiskIOError(code: ENOTDIR, operation: tr("Creazione cartella"), path: path)
        }
        let parent = (path as NSString).deletingLastPathComponent
        if parent != path { try createDirectories(parent, destination: d) }   // risale fino alla prima cartella esistente
        if mkdir(path, 0o755) != 0 && errno != EEXIST {
            throw DiskIOError(code: errno, operation: tr("Creazione cartella"), path: path)
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
        verifySignals[d].signal()
    }

    private var currentPhase: OffloadPhase {
        lock.lock(); defer { lock.unlock() }
        return phase
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
        let now = Date()
        // il tempo in pausa non conta (né per la durata né per le velocità)
        let elapsed = now.timeIntervalSince(startedAt) - pausedTotal - (pausedSince.map { now.timeIntervalSince($0) } ?? 0)
        if sampleRates && !pauseFlag {
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
        snap.isPaused = pauseFlag
        if !pauseFlag, phase != .finished {
            // l'operazione su disco ferma da più tempo (oltre la soglia) è quella da segnalare
            var worst: (Activity, TimeInterval)?
            for (activity, since) in activities {
                let age = now.timeIntervalSince(since)
                if age >= configuration.stallThreshold, age > (worst?.1 ?? 0) { worst = (activity, age) }
            }
            if let (activity, age) = worst {
                switch activity {
                case .readSource: snap.stall = StallWarning(kind: .sourceRead, seconds: age)
                case .writeDest(let d): snap.stall = StallWarning(kind: .destinationWrite(d), seconds: age)
                case .verifyDest(let d): snap.stall = StallWarning(kind: .destinationVerify(d), seconds: age)
                }
            }
        }
        var etas: [TimeInterval?] = []
        for d in job.destinationRoots.indices {
            var p = DestinationProgress(root: job.destinationRoots[d])
            p.totalBytes = destTotals[d]
            p.writtenBytes = writtenBytes[d]
            p.verifiedBytes = verifiedBytes[d]
            p.writeSpeed = phase == .copying ? writeRates[d].rate : 0
            p.verifySpeed = phase == .copying || phase == .verifying ? verifyRates[d].rate : 0
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
                             elapsed: Date().timeIntervalSince(startedAt) - pausedTotal)
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
