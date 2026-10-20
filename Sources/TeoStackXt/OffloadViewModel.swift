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
    @Published var destinations: [DestinationSlot] = [DestinationSlot()]
    @Published var snapshot = OffloadSnapshot()
    @Published var fileStates: [[DestFileStatus]] = []
    @Published var runState: RunState = .idle
    @Published var result: OffloadResult?
    @Published var errorMessage: String?
    @Published var resumable: OffloadJournal?

    private var scan: ScanResult?
    private var engine: OffloadEngine?
    private var activity: NSObjectProtocol?
    private let pendingLock = NSLock()
    private var pendingUpdates: [FileUpdate] = []

    let journalStore: JournalStore

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        journalStore = JournalStore(directory: support.appendingPathComponent("TeoStackXt/Journal", isDirectory: true))
        resumable = journalStore.latestResumable()
    }

    var isRunning: Bool { runState == .running }

    var canStart: Bool {
        runState == .idle && scan != nil && !rows.isEmpty
            && !destinations.isEmpty && destinations.allSatisfy { $0.url != nil }
    }

    // MARK: Sorgente

    func chooseSource() {
        if let url = pickFolder(message: "Seleziona la scheda (sorgente)") { setSource(url) }
    }

    func setSource(_ url: URL) {
        guard runState != .running else { return }
        sourceURL = url
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
        guard canStart, let scan, let source = sourceURL else { return }
        // Fase "progetti": qui la cartella di destinazione diventerà quella del bin scelto.
        let roots = destinations.compactMap { $0.url?.appendingPathComponent(source.lastPathComponent, isDirectory: true) }
        run(job: OffloadJob(sourceURL: source, destinationRoots: roots), scan: scan, resume: nil)
    }

    func resume() {
        guard let journal = resumable, runState == .idle else { return }
        let source = journal.job.sourceURL
        guard FileManager.default.fileExists(atPath: source.path) else {
            errorMessage = "La sorgente «\(source.path)» non è montata: inserire la scheda e riprovare."
            return
        }
        sourceURL = source
        destinations = journal.job.destinationRoots.map { DestinationSlot(url: $0.deletingLastPathComponent()) }
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

    private func run(job: OffloadJob, scan: ScanResult, resume: OffloadJournal?) {
        var config = OffloadEngine.Configuration()
        config.journalStore = journalStore
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
        for u in updates where u.fileIndex < fileStates.count {
            var row = fileStates[u.fileIndex]
            while row.count <= u.destinationIndex { row.append(.pending) }
            row[u.destinationIndex] = u.status
            fileStates[u.fileIndex] = row
        }
    }

    private func finish(_ result: OffloadResult) {
        flushUpdates()
        self.result = result
        runState = .idle
        engine = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        resumable = journalStore.latestResumable()
        if result.outcome == .preflightFailed {
            errorMessage = result.preflightErrors.joined(separator: "\n")
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
