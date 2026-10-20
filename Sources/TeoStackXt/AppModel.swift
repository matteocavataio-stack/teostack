#if canImport(SwiftUI)
import SwiftUI
import AppKit
import TeoStackCore

/// Contenitore dei due modelli dell'app. Non è osservato: le viste osservano i due modelli separatamente.
final class AppModel: ObservableObject {
    let projects: ProjectsViewModel
    let offload: OffloadViewModel
    let tools: ToolsViewModel

    init() {
        projects = ProjectsViewModel()
        offload = OffloadViewModel()
        tools = ToolsViewModel()
        offload.store = projects.store
        offload.onRecorded = { [weak projects] in projects?.reload() }
        // Dopo un offload completato i metadata dei clip verificati vengono letti automaticamente.
        offload.onOffloadFinished = { [weak projects] jobID in projects?.importMetadata(forJobID: jobID) }
    }
}

/// Presenza dei programmi esterni (ExifTool, ffprobe). L'app non li include: se mancano avvisa.
final class ToolsViewModel: ObservableObject {
    @Published var statuses: [ToolStatus] = []

    init() { recheck() }

    var missing: [ToolStatus] { statuses.filter { !$0.isAvailable } }

    func recheck() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = ExternalTools.detectAll()
            DispatchQueue.main.async { self?.statuses = found }
        }
    }

    /// Indica a mano dove si trova un programma (es. art-cmd se è stato estratto in una cartella non standard).
    func choosePath(for tool: ExternalTool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Seleziona il programma «\(tool.executableName)»"
        panel.prompt = "Scegli"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        ExternalTools.setUserPath(url.path, for: tool)
        recheck()
    }
}

/// Progetti, albero Library → giorno → bin e tabella clip. Le proprietà vengono modificate SOLO dal thread principale.
final class ProjectsViewModel: ObservableObject {
    let store: ProjectStore?
    @Published var projects: [ProjectSummary] = []
    @Published var selectedProjectID: Int64?
    @Published var tree: TreeNode?
    @Published var selectedNodeID: Int64?
    @Published var clips: [ClipRecord] = []
    @Published var history: [HistoryEvent] = []
    @Published var binTarget: BinTarget?
    @Published var showAllFiles = false
    @Published var errorMessage: String?
    @Published var metadataStatus: String?
    @Published var isReadingMetadata = false
    @Published var thumbnailStatus: String?
    @Published var isGeneratingThumbnails = false
    /// Aumenta ogni volta che cambiano le anteprime su disco: fa ridisegnare la tabella.
    @Published var thumbnailRevision = 0

    let thumbnails = ThumbnailCache(directory: ThumbnailCache.defaultDirectory())

    private static let lastProjectKey = "lastProjectID"

    init() {
        do {
            store = try ProjectStore(path: ProjectStore.defaultDatabasePath())
        } catch {
            store = nil
            errorMessage = "Impossibile aprire il database dei progetti: \(error)"
        }
        reload()
    }

    var selectedProject: ProjectSummary? { projects.first { $0.id == selectedProjectID } }

    // MARK: Lettura

    func reload() {
        guard let store else { return }
        do {
            projects = try store.projects()
            if selectedProjectID == nil || !projects.contains(where: { $0.id == selectedProjectID }) {
                let saved = Int64(UserDefaults.standard.integer(forKey: Self.lastProjectKey))
                selectedProjectID = projects.first(where: { $0.id == saved })?.id ?? projects.first?.id
            }
            try reloadTree()
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func reloadTree() throws {
        guard let store, let pid = selectedProjectID else {
            tree = nil; selectedNodeID = nil; clips = []; history = []; binTarget = nil
            return
        }
        let t = try store.tree(projectID: pid)
        tree = t
        if selectedNodeID == nil || node(selectedNodeID!) == nil { selectedNodeID = t.id }
        history = try store.history(projectID: pid)
        try refreshSelection()
    }

    private func refreshSelection() throws {
        guard let store else { return }
        if let id = selectedNodeID {
            clips = try store.clips(underNode: id, mediaOnly: !showAllFiles)
            if let n = node(id), n.kind == .bin { binTarget = try store.binTarget(binID: id) } else { binTarget = nil }
        } else {
            clips = []; binTarget = nil
        }
    }

    func node(_ id: Int64) -> TreeNode? {
        func find(_ n: TreeNode) -> TreeNode? {
            if n.id == id { return n }
            for c in n.children ?? [] { if let f = find(c) { return f } }
            return nil
        }
        return tree.flatMap(find)
    }

    func parent(of id: Int64) -> TreeNode? {
        guard let pid = node(id)?.parentID else { return nil }
        return node(pid)
    }

    /// Giorno corrente: quello selezionato, o quello che contiene il bin selezionato.
    var currentDay: TreeNode? {
        guard let id = selectedNodeID, let n = node(id) else { return nil }
        if n.kind == .day { return n }
        if n.kind == .bin { return parent(of: n.id) }
        return nil
    }

    var suggestedDayName: String {
        NameSuggestions.dayName(existingDayCount: tree?.children?.count ?? 0)
    }

    // MARK: Selezione

    func selectProject(_ id: Int64?) {
        selectedProjectID = id
        selectedNodeID = nil
        if let id { UserDefaults.standard.set(Int(id), forKey: Self.lastProjectKey) }
        run { try reloadTree() }
    }

    func selectNode(_ id: Int64?) {
        selectedNodeID = id
        run { try refreshSelection() }
    }

    func setShowAllFiles(_ value: Bool) {
        showAllFiles = value
        run { try refreshSelection() }
    }

    // MARK: Modifiche (restituiscono il messaggio d'errore da mostrare nella finestra di dialogo, o nil)

    func createProject(name: String) -> String? {
        mutate { store in
            let p = try store.createProject(name: name)
            selectedProjectID = p.id
            selectedNodeID = nil
            UserDefaults.standard.set(Int(p.id), forKey: Self.lastProjectKey)
        }
    }

    func renameProject(name: String) -> String? {
        guard let id = selectedProjectID else { return "Nessun progetto selezionato." }
        return mutate { try $0.renameProject(id: id, to: name) }
    }

    func deleteProject() {
        guard let id = selectedProjectID else { return }
        _ = mutate { store in
            try store.deleteProject(id: id)
            selectedProjectID = nil
            selectedNodeID = nil
        }
    }

    func createDay(name: String) -> String? {
        guard let pid = selectedProjectID else { return "Nessun progetto selezionato." }
        return mutate { store in
            let d = try store.createDay(projectID: pid, name: name)
            selectedNodeID = d.id
        }
    }

    func createBin(name: String) -> String? {
        guard let day = currentDay else { return "Seleziona prima una cartella giorno." }
        return mutate { store in
            let b = try store.createBin(dayID: day.id, name: name)
            selectedNodeID = b.id
        }
    }

    func renameNode(id: Int64, name: String) -> String? {
        mutate { try $0.renameNode(id: id, to: name) }
    }

    func deleteNode(id: Int64) {
        _ = mutate { store in
            let parentID = node(id)?.parentID
            try store.deleteNode(id: id)
            selectedNodeID = parentID
        }
    }

    func deletionImpact(id: Int64) -> ProjectStore.DeletionImpact? {
        try? store?.deletionImpact(nodeID: id)
    }

    func offloadCount(binID: Int64) -> Int {
        (try? store?.offloads(binID: binID).count) ?? 0
    }

    // MARK: Metadata

    /// Legge i metadata dei clip di un offload appena concluso.
    func importMetadata(forJobID jobID: UUID) {
        guard let store else { return }
        runMetadataImport(clips: (try? store.clips(forJobID: jobID)) ?? [], thumbnailsForJobID: jobID)
    }

    /// Rilegge i metadata di tutti i clip mostrati (selezione corrente).
    func readMetadataForSelection() {
        runMetadataImport(clips: clips)
    }

    private func runMetadataImport(clips: [ClipRecord], thumbnailsForJobID: UUID? = nil) {
        guard let store, !clips.isEmpty, !isReadingMetadata else { return }
        let exif = ExifToolRunner.locate()
        let art = ARTCmdRunner.locate()
        guard exif != nil || art != nil else {
            metadataStatus = "Né ExifTool né art-cmd sono installati: metadata non letti (vedi l'avviso in alto per installarli)."
            if let job = thumbnailsForJobID { generateThumbnails(forJobID: job) }
            return
        }
        isReadingMetadata = true
        metadataStatus = "Lettura metadata…"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let summary = try MetadataImporter.importMetadata(for: clips, store: store, runner: exif, art: art) { done, total in
                    DispatchQueue.main.async { self?.metadataStatus = "Lettura metadata… \(done)/\(total)" }
                }
                DispatchQueue.main.async {
                    self?.finishMetadataImport("Metadata: \(summary.text)")
                    if let job = thumbnailsForJobID { self?.generateThumbnails(forJobID: job) }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.finishMetadataImport("Metadata non letti: \(error)")
                    if let job = thumbnailsForJobID { self?.generateThumbnails(forJobID: job) }
                }
            }
        }
    }

    private func finishMetadataImport(_ text: String) {
        isReadingMetadata = false
        metadataStatus = text
        run { try refreshSelection() }
    }

    // MARK: Anteprime (primo fotogramma)

    /// Crea le anteprime dei clip di un offload appena concluso (dopo la lettura dei metadata, che servono a riconoscere i clip ARRI).
    func generateThumbnails(forJobID jobID: UUID) {
        guard let store else { return }
        runThumbnails(clips: (try? store.clips(forJobID: jobID)) ?? [], regenerate: false)
    }

    /// Crea (o ritenta) le anteprime dei clip mostrati.
    func generateThumbnailsForSelection(regenerate: Bool) {
        runThumbnails(clips: clips, regenerate: regenerate)
    }

    private func runThumbnails(clips: [ClipRecord], regenerate: Bool) {
        guard let store, !clips.isEmpty, !isGeneratingThumbnails else { return }
        let tools = ThumbnailTools()
        guard tools.art != nil || tools.ffmpeg != nil else {
            thumbnailStatus = "Né ffmpeg né art-cmd sono installati: anteprime non create (vedi l'avviso in alto per installarli)."
            return
        }
        isGeneratingThumbnails = true
        thumbnailStatus = "Creazione anteprime…"
        let cache = thumbnails
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let summary = try ThumbnailGenerator.generate(for: clips, store: store, tools: tools, cache: cache, regenerate: regenerate) { done, total in
                    DispatchQueue.main.async {
                        self?.thumbnailStatus = "Creazione anteprime… \(done)/\(total)"
                        self?.thumbnailRevision += 1
                    }
                }
                DispatchQueue.main.async { self?.finishThumbnails("Anteprime: \(summary.text)") }
            } catch {
                DispatchQueue.main.async { self?.finishThumbnails("Anteprime non create: \(error)") }
            }
        }
    }

    private func finishThumbnails(_ text: String) {
        isGeneratingThumbnails = false
        thumbnailStatus = text
        thumbnailRevision += 1
    }

    // MARK: Interni

    private func run(_ body: () throws -> Void) {
        do { try body() } catch { errorMessage = "\(error)" }
    }

    private func mutate(_ body: (ProjectStore) throws -> Void) -> String? {
        guard let store else { return "Database dei progetti non disponibile." }
        do {
            try body(store)
            reload()
            return nil
        } catch {
            return "\(error)"
        }
    }
}
#endif
