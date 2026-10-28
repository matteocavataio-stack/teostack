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
    /// Percorsi di destinazione salvati dall'utente (menu «Percorsi salvati»).
    @Published private(set) var savedPaths: [String] = SavedPathsStore().paths
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

    private let savedStore = SavedPathsStore()
    private static let destinationsKey = "lastDestinations"

    /// Cartelle di destinazione dell'ultimo offload che esistono ancora (i dischi scollegati vengono scartati).
    static func savedDestinations() -> [DestinationSlot] {
        let paths = UserDefaults.standard.stringArray(forKey: destinationsKey) ?? []
        let slots = paths.prefix(OffloadJob.maxDestinations).compactMap { path -> DestinationSlot? in
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
        if let url = pickFolder(message: tr("Seleziona la scheda (sorgente)")) { setSource(url) }
    }

    /// «Svuota la sorgente a fine offload» (impostazione dell'app, attiva se non è mai stata cambiata).
    static var clearSourceWhenDone: Bool {
        UserDefaults.standard.object(forKey: "clearSourceWhenDone") as? Bool ?? true
    }

    /// Scheda dell'ultimo offload riuscito dopo che la parte «Sorgente» si è svuotata da sola: serve per «Espelli sorgente».
    private var finishedSourceVolume: URL?

    /// Svuota SOLO la parte «Sorgente» (elenco file, nome del bin, dimensione), pronta per la scheda successiva.
    /// Destinazioni, avanzamento, esito e cronologia restano; la scheda resta espellibile.
    private func clearSource() {
        finishedSourceVolume = ejectableSourceVolume
        sourceURL = nil
        rows = []
        totalSize = 0
        skippedItems = []
        fileStates = []
        scan = nil
        binName = ""
    }

    func setSource(_ url: URL) {
        guard runState != .running else { return }
        finishedSourceVolume = nil
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
                    self?.errorMessage = tr("Impossibile leggere la sorgente: {0}", error)
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
        guard !isRunning, let url = pickFolder(message: tr("Seleziona la cartella di destinazione")) else { return }
        if let i = destinations.firstIndex(where: { $0.id == slot.id }) { destinations[i].url = url }
    }

    func addDestination() {
        if destinations.count < OffloadJob.maxDestinations, !isRunning { destinations.append(DestinationSlot()) }
    }

    // MARK: Percorsi salvati

    /// Si salvano i percorsi scelti, così non vanno selezionati ogni volta (nessun file viene toccato).
    var canSaveChosenDestinations: Bool {
        destinations.contains { slot in slot.url.map { !savedStore.contains($0.path) } ?? false }
    }

    func saveChosenDestinations() {
        for slot in destinations { if let path = slot.url?.path { savedStore.add(path) } }
        savedPaths = savedStore.paths
    }

    func removeSavedPath(_ path: String) {
        savedStore.remove(path)
        savedPaths = savedStore.paths
    }

    func isSavedPathAvailable(_ path: String) -> Bool { SavedPathsStore.isAvailable(path) }

    /// Mette il percorso salvato in una destinazione precisa.
    func assignSavedPath(_ path: String, to slot: DestinationSlot) {
        guard !isRunning, let i = destinations.firstIndex(where: { $0.id == slot.id }) else { return }
        destinations[i].url = URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Mette il percorso salvato nella prima destinazione vuota; se non ce ne sono ne aggiunge una (fino al massimo).
    func useSavedPath(_ path: String) {
        guard !isRunning else { return }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        if destinations.contains(where: { $0.url.map { SavedPathsStore.normalized($0.path) == SavedPathsStore.normalized(path) } ?? false }) { return }
        if let i = destinations.firstIndex(where: { $0.url == nil }) {
            destinations[i].url = url
        } else if destinations.count < OffloadJob.maxDestinations {
            destinations.append(DestinationSlot(url: url))
        } else {
            errorMessage = tr("Ci sono già {0} destinazioni (il massimo): rimuovine una prima.", OffloadJob.maxDestinations)
        }
    }

    /// Usa tutti i percorsi salvati disponibili (fino al massimo) al posto delle destinazioni attuali.
    func useAllSavedPaths() {
        guard !isRunning else { return }
        let available = savedPaths.filter { SavedPathsStore.isAvailable($0) }.prefix(OffloadJob.maxDestinations)
        guard !available.isEmpty else { return }
        destinations = available.map { DestinationSlot(url: URL(fileURLWithPath: $0, isDirectory: true)) }
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
        panel.prompt = tr("Scegli")
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
                errorMessage = tr("Bin non trovato dopo la creazione.")
                return
            }
            target = t
            onBinReady?(bin.node.id)
        } catch {
            errorMessage = tr("Impossibile creare il bin «{0}»: {1}", binName, error)
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
            errorMessage = tr("La sorgente «{0}» non è montata: inserire la scheda e riprovare.", source.path)
            return
        }
        // L'offload deve essere ancora registrato in un bin del progetto (altrimenti il bin è stato eliminato).
        guard let record = try? store?.offloadRecord(jobID: journal.job.id) else {
            errorMessage = tr("Il bin di questo offload è stato eliminato dal progetto: non posso riprenderlo registrandolo. Crea un nuovo bin e rilancia l'offload (i file già copiati e identici vengono solo verificati, mai riscritti).")
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
                    self?.errorMessage = tr("Impossibile leggere la sorgente: {0}", error)
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
            errorMessage = tr("Database dei progetti non disponibile: offload non avviato.")
            return false
        }
        do {
            try store.beginOffload(jobID: job.id, binID: binID, sourcePath: job.sourceURL.path,
                                   destinations: job.destinationRoots.map { $0.path })
            return true
        } catch {
            errorMessage = tr("Impossibile registrare l'offload nel progetto: {0}", error)
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
            reason: tr("Offload in corso"))

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
            errorMessage = tr("L'offload è terminato ma non sono riuscito a registrarlo nel progetto: {0}", error)
        }
        onRecorded?()
        if result.outcome == .completed { onOffloadFinished?(result.job.id) }
        notifyFinished(result)
        if result.outcome == .preflightFailed {
            errorMessage = result.preflightErrors.joined(separator: "\n")
        }
        // Con tutti i file OK (e l'offload registrato) la sorgente si svuota da sola. Con problemi o annullato resta l'elenco dei file,
        // perché serve a vedere quali non sono andati a buon fine e a «Riprendi».
        if result.outcome == .completed, result.allOK, errorMessage == nil, Self.clearSourceWhenDone { clearSource() }
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
        if sourceURL == nil, let volume = finishedSourceVolume {      // dopo lo svuotamento automatico della sorgente
            return Self.connectedVolumes().contains(where: { $0.path == volume.path }) ? volume : nil
        }
        guard let source = sourceURL, let volume = try? source.resourceValues(forKeys: [.volumeURLKey]).volume,
              Self.connectedVolumes().contains(where: { $0.path == volume.path }) else { return nil }
        return volume
    }

    /// Espelle la scheda sorgente (solo su richiesta, dopo un offload con tutti i file OK).
    func ejectSource() {
        guard let volume = ejectableSourceVolume else { return }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
            if sourceURL == nil { finishedSourceVolume = nil }
        } catch {
            errorMessage = tr("Impossibile espellere «{0}»: {1}", volume.lastPathComponent, error.localizedDescription)
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
