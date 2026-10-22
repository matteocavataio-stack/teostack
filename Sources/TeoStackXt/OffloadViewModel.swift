#if canImport(SwiftUI)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TeoStackCore

struct DestinationSlot: Identifiable {
    let id = UUID()
    var url: URL?
}

struct FileRow: Identifiable {
    let index: Int
    let file: SourceFile
    var id: String { file.relativePath }
}

enum RunState {
    case idle, scanning, running
}

/// Tutto lo stato dell'interfaccia di offload. Le proprietà vengono modificate SOLO dal thread principale.
final class OffloadViewModel: ObservableObject {
    @Published var sourceURL: URL?
    @Published var rows: [FileRow] = []
    @Published var totalSize: Int64 = 0
    @Published var skippedItems: [SkippedItem] = []
    @Published var destinations: [DestinationSlot] = [DestinationSlot()] {
        didSet { Self.saveDestinations(destinations) }
    }
    @Published var snapshot = OffloadSnapshot()
    @Published var fileStates: [[DestFileStatus]] = []
    @Published var runState: RunState = .idle
    @Published var result: OffloadResult?
    @Published var errorMessage: String?
    @Published var resumable: OffloadJournal?

    /// Cartella del progetto in cui nascerà il bin e nome del bin (proposto dalla sorgente, modificabile prima dell'avvio).
    /// Su disco la destinazione è <cartella scelta>/<nome bin>.
    @Published var placement: BinPlacement?
    @Published var binName = ""
    var store: ProjectStore?
    var onBinReady: ((Int64) -> Void)?
    var onRecorded: (() -> Void)?
    var onOffloadFinished: ((UUID) -> Void)?

    private var scan: ScanResult?
    private var engine: OffloadEngine?
    private var activity: NSObjectProtocol?
    private let pendingLock = NSLock()
    private var pendingUpdates: [FileUpdate] = []

    let journalStore: JournalStore

    private static let destinationsKey = "lastDestinations"

    /// Cartelle di destinazione dell'ultimo offload che esistono ancora (i dischi scollegati vengono scartati).
    static func savedDestinations() -> [DestinationSlot] {
        let paths = UserDefaults.standard.stringArray(forKey: destinationsKey) ?? []
        let slots = paths.prefix(3).compactMap { path -> DestinationSlot? in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue ? DestinationSlot(url: URL(fileURLWithPath: path)) : nil
        }
        return slots.isEmpty ? [DestinationSlot()] : slots
    }

    private static func saveDestinations(_ slots: [DestinationSlot]) {
        UserDefaults.standard.set(slots.compactMap { $0.url?.path }, forKey: destinationsKey)
    }

    init() {
        destinations = Self.savedDestinations()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        journalStore = JournalStore(directory: support.appendingPathComponent("TeoStackXt/Journal", isDirectory: true))
        resumable = journalStore.latestResumable()
    }

    var isRunning: Bool { runState == .running }

    /// «Verifica durante la copia» (impostazione dell'app, attiva se non è mai stata cambiata).
    static var overlapVerificationEnabled: Bool {
        UserDefaults.standard.object(forKey: "overlapVerification") as? Bool ?? true
    }

    var canStart: Bool {
        runState == .idle && scan != nil && !rows.isEmpty && placement != nil && binNameError == nil
            && !destinations.isEmpty && destinations.allSatisfy { $0.url != nil }
    }

    /// nil se il nome del bin è valido.
    var binNameError: String? {
        do { _ = try NameValidator.validated(binName); return nil } catch { return "\(error)" }
    }

    // MARK: Sorgente

    func chooseSource() {
        if let url = pickFolder(message: "Seleziona la scheda (sorgente)") { setSource(url) }
    }

    func setSource(_ url: URL) {
        guard runState != .running else { return }
        sourceURL = url
        binName = NameValidator.suggestedBinName(fromSource: url.lastPathComponent)
        result = nil
        errorMessage = nil
        rows = []
        totalSize = 0
        scan = nil
        runState = .scanning
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let scan = try SourceScanner.scan(root: url)
                DispatchQueue.main.async { self?.didScan(scan) }
            } catch {
                DispatchQueue.main.async {
                    self?.runState = .idle
                    self?.errorMessage = "Impossibile leggere la sorgente: \(error)"
                }
            }
        }
    }

    private func didScan(_ scan: ScanResult) {
        self.scan = scan
        rows = scan.files.enumerated().map { FileRow(index: $0.offset, file: $0.element) }
        totalSize = scan.totalSize
        skippedItems = scan.skipped
        fileStates = scan.files.map { _ in [] }
        runState = .idle
    }

    // MARK: Destinazioni

    func chooseDestination(_ slot: DestinationSlot) {
        guard !isRunning, let url = pickFolder(message: "Seleziona la cartella di destinazione") else { return }
        if let i = destinations.firstIndex(where: { $0.id == slot.id }) { destinations[i].url = url }
    }

    func addDestination() {
        if destinations.count < 3, !isRunning { destinations.append(DestinationSlot()) }
    }

    func removeDestination(_ slot: DestinationSlot) {
        if destinations.count > 1, !isRunning { destinations.removeAll { $0.id == slot.id } }
    }

    private func pickFolder(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.prompt = "Scegli"
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: Avvio / Annulla / Riprendi

    func start() {
        guard canStart, let scan, let source = sourceURL, let placement, let store else { return }
        // Il bin nasce ora, con il nome scelto (se esiste già nella cartella lo riusa: l'offload si aggiunge).
        let target: BinTarget
        do {
            let bin = try store.findOrCreateBin(parentID: placement.parentID, name: binName)
            guard let t = try store.binTarget(binID: bin.node.id) else {
                errorMessage = "Bin non trovato dopo la creazione."
                return
            }
            target = t
            onBinReady?(bin.node.id)
        } catch {
            errorMessage = "Impossibile creare il bin «\(binName)»: \(error)"
            return
        }
        let bases = destinations.compactMap { $0.url }
        let roots = bases.map { target.destinationRoot(under: $0) }
        let job = OffloadJob(sourceURL: source, destinationRoots: roots, destinationBases: bases)
        guard register(job: job, binID: target.binID) else { return }
        run(job: job, scan: scan, resume: nil)
    }

    func resume() {
        guard let journal = resumable, runState == .idle else { return }
        let source = journal.job.sourceURL
        guard FileManager.default.fileExists(atPath: source.path) else {
            errorMessage = "La sorgente «\(source.path)» non è montata: inserire la scheda e riprovare."
            return
        }
        // L'offload deve essere ancora registrato in un bin del progetto (altrimenti il bin è stato eliminato).
        guard let record = try? store?.offloadRecord(jobID: journal.job.id) else {
            errorMessage = "Il bin di questo offload è stato eliminato dal progetto: non posso riprenderlo registrandolo. Crea un nuovo bin e rilancia l'offload (i file già copiati e identici vengono solo verificati, mai riscritti)."
            return
        }
        guard register(job: journal.job, binID: record.binID) else { return }
        sourceURL = source
        destinations = (journal.job.destinationBases ?? journal.job.destinationRoots.map { $0.deletingLastPathComponent() })
            .map { DestinationSlot(url: $0) }
        runState = .scanning
        result = nil
        errorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let scan = try SourceScanner.scan(root: source)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.didScan(scan)
                    self.run(job: journal.job, scan: scan, resume: journal)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.runState = .idle
                    self?.errorMessage = "Impossibile leggere la sorgente: \(error)"
                }
            }
        }
    }

    func cancel() {
        engine?.cancel()
    }

    /// Registra l'offload nel bin PRIMA di iniziare. Se la registrazione fallisce non si parte.
    private func register(job: OffloadJob, binID: Int64) -> Bool {
        guard let store else {
            errorMessage = "Database dei progetti non disponibile: offload non avviato."
            return false
        }
        do {
            try store.beginOffload(jobID: job.id, binID: binID, sourcePath: job.sourceURL.path,
                                   destinations: job.destinationRoots.map { $0.path })
            return true
        } catch {
            errorMessage = "Impossibile registrare l'offload nel progetto: \(error)"
            return false
        }
    }

    private func run(job: OffloadJob, scan: ScanResult, resume: OffloadJournal?) {
        var config = OffloadEngine.Configuration()
        config.journalStore = journalStore
        config.overlapVerification = Self.overlapVerificationEnabled
        let engine = OffloadEngine(job: job, scan: scan, configuration: config, resume: resume)
        self.engine = engine
        runState = .running
        result = nil
        errorMessage = nil
        snapshot = OffloadSnapshot()
        fileStates = scan.files.map { _ in Array(repeating: .pending, count: job.destinationRoots.count) }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Offload in corso")

        engine.onFileUpdate = { [weak self] update in
            guard let self else { return }
            self.pendingLock.lock(); self.pendingUpdates.append(update); self.pendingLock.unlock()
        }
        engine.onSnapshot = { [weak self] snap in
            DispatchQueue.main.async {
                self?.flushUpdates()
                self?.snapshot = snap
            }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = engine.run()
            DispatchQueue.main.async { self?.finish(result) }
        }
    }

    private func flushUpdates() {
        pendingLock.lock()
        let updates = pendingUpdates
        pendingUpdates.removeAll()
        pendingLock.unlock()
        guard !updates.isEmpty else { return }
        var states = fileStates
        for u in updates where u.fileIndex < states.count {
            while states[u.fileIndex].count <= u.destinationIndex { states[u.fileIndex].append(.pending) }
            states[u.fileIndex][u.destinationIndex] = u.status
        }
        fileStates = states          // una sola pubblicazione per tutti gli aggiornamenti accumulati
    }

    private func finish(_ result: OffloadResult) {
        flushUpdates()
        self.result = result
        runState = .idle
        engine = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        resumable = journalStore.latestResumable()
        do { try store?.finishOffload(result) } catch {
            errorMessage = "L'offload è terminato ma non sono riuscito a registrarlo nel progetto: \(error)"
        }
        onRecorded?()
        if result.outcome == .completed { onOffloadFinished?(result.job.id) }
        notifyFinished(result)
        if result.outcome == .preflightFailed {
            errorMessage = result.preflightErrors.joined(separator: "\n")
        }
    }

    /// Suono (diverso se ci sono problemi) e rimbalzo nel Dock se l'app non è in primo piano.
    private func notifyFinished(_ result: OffloadResult) {
        guard result.outcome != .cancelled else { return }
        if UserDefaults.standard.object(forKey: "soundOnFinish") as? Bool ?? true {
            NSSound(named: result.outcome == .completed && result.allOK ? "Glass" : "Basso")?.play()
        }
        if !NSApp.isActive { NSApp.requestUserAttention(result.allOK ? .informationalRequest : .criticalRequest) }
    }

    // MARK: Schede collegate e espulsione

    /// Volumi esterni/rimovibili montati (schede e dischi), per sceglierli con un clic come sorgente.
    static func connectedVolumes() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsInternalKey, .volumeIsRootFileSystemKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeNameKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.filter { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return false }
            if v.volumeIsRootFileSystem == true { return false }
            return v.volumeIsInternal != true || v.volumeIsRemovable == true || v.volumeIsEjectable == true
        }
    }

    /// Volume su cui si trova la sorgente, se è un disco esterno che si può espellere.
    var ejectableSourceVolume: URL? {
        guard let source = sourceURL, let volume = try? source.resourceValues(forKeys: [.volumeURLKey]).volume,
              Self.connectedVolumes().contains(where: { $0.path == volume.path }) else { return nil }
        return volume
    }

    /// Espelle la scheda sorgente (solo su richiesta, dopo un offload con tutti i file OK).
    func ejectSource() {
        guard let volume = ejectableSourceVolume else { return }
        do { try NSWorkspace.shared.unmountAndEjectDevice(at: volume) } catch {
            errorMessage = "Impossibile espellere «\(volume.lastPathComponent)»: \(error.localizedDescription)"
        }
    }

    // MARK: Per la tabella

    func aggregateStatus(_ index: Int) -> DestFileStatus? {
        guard index < fileStates.count else { return nil }
        let states = fileStates[index]
        if states.isEmpty { return nil }
        if states.contains(.mismatch) { return .mismatch }
        if states.contains(.error) { return .error }
        if states.allSatisfy({ $0 == .ok }) { return .ok }
        if states.contains(.verifying) { return .verifying }
        if states.contains(.copying) { return .copying }
        if states.contains(.copied) { return .copied }
        return .pending
    }
}
#endif
