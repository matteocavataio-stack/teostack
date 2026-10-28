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
        offload.onBinReady = { [weak projects] id in projects?.binRegistered(id: id) }
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
        panel.message = tr("Seleziona il programma «{0}»", tool.executableName)
        panel.prompt = tr("Scegli")
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
    /// Riepilogo di quanto scaricato nel nodo selezionato (spazio, clip, schede, durata, formati).
    @Published var recap: ProjectRecap?
    /// Dove verrà creato il bin del prossimo offload: la cartella selezionata (o quella che contiene il bin selezionato).
    @Published var placement: BinPlacement?
    @Published var showAllFiles = false
    @Published var errorMessage: String?
    @Published var metadataStatus: String?
    @Published var isReadingMetadata = false
    @Published var thumbnailStatus: String?
    @Published var isGeneratingThumbnails = false
    @Published var isImporting = false
    /// Esito dell'ultima importazione («Importa media»).
    @Published var importStatus: String?
    /// Aumenta ogni volta che cambiano le anteprime su disco: fa ridisegnare la tabella.
    @Published var thumbnailRevision = 0

    let thumbnails = ThumbnailCache(directory: ThumbnailCache.defaultDirectory())

    private static let lastProjectKey = "lastProjectID"

    init() {
        do {
            store = try ProjectStore(path: ProjectStore.defaultDatabasePath())
        } catch {
            store = nil
            errorMessage = tr("Impossibile aprire il database dei progetti: {0}", error)
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
            tree = nil; selectedNodeID = nil; clips = []; history = []; placement = nil; recap = nil
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
            let all = try store.clips(underNode: id, mediaOnly: false)
            clips = showAllFiles ? all : all.filter { $0.isMedia }
            recap = ProjectRecap.make(clips: all, offloads: try store.offloads(underNode: id))
            placement = computePlacement()
        } else {
            clips = []; placement = nil; recap = nil
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

    /// Cartella in cui si creano nuove cartelle e bin: quella selezionata, o quella che contiene il bin selezionato.
    var currentContainer: TreeNode? {
        guard let id = selectedNodeID, let n = node(id) else { return nil }
        return n.kind == .bin ? parent(of: n.id) : n
    }

    private func computePlacement() -> BinPlacement? {
        guard let project = selectedProject, let container = currentContainer else { return nil }
        var path: [String] = []
        var cursor: TreeNode? = container
        while let n = cursor, n.kind != .library { path.insert(n.name, at: 0); cursor = n.parentID.flatMap(node) }
        return BinPlacement(projectID: project.id, projectName: project.name, parentID: container.id, parentPath: path)
    }

    /// Bin con questo nome già presente nella cartella di destinazione (stesso criterio del disco: maiuscole indifferenti).
    func existingBin(named name: String) -> TreeNode? {
        guard let placement, let container = node(placement.parentID) else { return nil }
        let wanted = name.trimmingCharacters(in: .whitespaces)
        return container.children?.first { $0.kind == .bin && $0.name.compare(wanted, options: .caseInsensitive) == .orderedSame }
    }

    /// Chiamato quando l'offload crea (o riusa) il bin: aggiorna l'albero e lo seleziona.
    func binRegistered(id: Int64) {
        selectedNodeID = id
        run { try reloadTree() }
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
        guard let id = selectedProjectID else { return tr("Nessun progetto selezionato.") }
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
        guard let pid = selectedProjectID else { return tr("Nessun progetto selezionato.") }
        return mutate { store in
            let d = try store.createDay(projectID: pid, name: name)
            selectedNodeID = d.id
        }
    }

    func createFolder(name: String) -> String? {
        guard let container = currentContainer else { return tr("Seleziona prima un progetto.") }
        return mutate { store in
            let f = try store.createFolder(parentID: container.id, name: name)
            selectedNodeID = f.id
        }
    }

    struct MoveTarget: Identifiable {
        let id: Int64
        let label: String
    }

    /// Cartelle in cui si può spostare l'elemento (esclusi se stesso, i suoi discendenti e la cartella attuale).
    func moveTargets(for id: Int64) -> [MoveTarget] {
        guard let moving = node(id), moving.kind != .library else { return [] }
        var out: [MoveTarget] = []
        func visit(_ n: TreeNode, path: [String]) {
            if n.id == id { return }                                   // né sé stesso né i suoi discendenti
            guard n.kind != .bin else { return }
            let here = n.kind == .library ? path : path + [n.name]
            let allowed = moving.kind == .day ? n.kind == .library : true
            if allowed && n.id != moving.parentID {
                out.append(MoveTarget(id: n.id, label: n.kind == .library ? tr("Library (radice)") : here.joined(separator: " › ")))
            }
            for c in n.children ?? [] { visit(c, path: here) }
        }
        if let tree { visit(tree, path: []) }
        return out
    }

    func moveNode(id: Int64, toParent parentID: Int64) {
        if let message = mutate({ try $0.moveNode(id: id, toParentID: parentID) }) { errorMessage = message }
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

    func clearHistory() {
        guard let id = selectedProjectID else { return }
        _ = mutate { try $0.clearHistory(projectID: id) }
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
        runMetadataImport(clips: (try? store.clips(forJobID: jobID)) ?? [], thumbnailsForJobIDs: [jobID])
    }

    // MARK: Importa media (clip aggiunti senza scaricarli)

    /// Sceglie cartelle o file già presenti su disco e li registra nel progetto SENZA copiarli né toccarli: servono a leggere i metadata
    /// e a esportare i report. Ogni cartella diventa un bin (col nome della cartella) dentro la cartella selezionata; i file singoli
    /// vanno nel bin della loro cartella. I clip importati risultano «Importato», mai «OK» (nessuna copia è stata verificata).
    func importMedia() {
        guard let store, let container = currentContainer else { errorMessage = tr("Seleziona prima un progetto."); return }
        guard !isImporting else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = tr("Scegli le cartelle o i file da importare. Non vengono copiati né modificati: servono a leggere i metadata e a esportare i report.")
        panel.prompt = tr("Importa")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        let parentID = container.id
        isImporting = true
        importStatus = tr("Importazione in corso…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                var imports: [(binID: Int64, result: ProjectStore.ImportResult)] = []
                var skipped = 0
                for group in try SourceScanner.importBins(for: urls) {
                    skipped += group.skipped.count
                    guard !group.files.isEmpty else { continue }
                    let bin = try store.findOrCreateBin(parentID: parentID, name: group.name.isEmpty ? tr("Importati") : group.name).node
                    imports.append((bin.id, try store.importFiles(binID: bin.id, rootPath: group.root.path, files: group.files)))
                }
                DispatchQueue.main.async { self?.finishImport(imports, skipped: skipped) }
            } catch {
                DispatchQueue.main.async {
                    self?.isImporting = false
                    self?.importStatus = nil
                    self?.errorMessage = "\(error)"
                }
            }
        }
    }

    private func finishImport(_ imports: [(binID: Int64, result: ProjectStore.ImportResult)], skipped: Int) {
        isImporting = false
        let added = imports.reduce(0) { $0 + $1.result.added }
        let already = imports.reduce(0) { $0 + $1.result.alreadyPresent }
        var text = tr("Importati {0} file in {1} bin ({2} già presenti).", added, imports.count, already)
        if skipped > 0 { text += " " + tr("{0} elementi non importabili (collegamenti o file speciali).", skipped) }
        importStatus = imports.isEmpty ? tr("Nessun file da importare nella selezione.") : text
        if let last = imports.last { binRegistered(id: last.binID) } else { reload() }
        // metadata e anteprime dei file appena importati
        if let store {
            let clips = imports.flatMap { (try? store.clips(forJobID: $0.result.jobID)) ?? [] }
            runMetadataImport(clips: clips, thumbnailsForJobIDs: imports.map { $0.result.jobID })
        }
    }

    /// Rilegge i metadata di tutti i clip mostrati (selezione corrente).
    func readMetadataForSelection() {
        runMetadataImport(clips: clips)
    }

    private func runMetadataImport(clips: [ClipRecord], thumbnailsForJobIDs: [UUID] = []) {
        guard let store, !clips.isEmpty, !isReadingMetadata else { return }
        let exif = ExifToolRunner.locate()
        let art = ARTCmdRunner.locate()
        let probe = FFprobeRunner.locate()
        guard exif != nil || art != nil || probe != nil else {
            metadataStatus = tr("Né ExifTool né art-cmd né ffprobe sono installati: metadata non letti (vedi l'avviso in alto per installarli).")
            generateThumbnails(forJobIDs: thumbnailsForJobIDs)
            return
        }
        isReadingMetadata = true
        metadataStatus = tr("Lettura metadata…")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let summary = try MetadataImporter.importMetadata(for: clips, store: store, runner: exif, art: art, probe: probe) { done, total in
                    DispatchQueue.main.async { self?.metadataStatus = tr("Lettura metadata… {0}/{1}", done, total) }
                }
                DispatchQueue.main.async {
                    self?.finishMetadataImport(tr("Metadata: {0}", summary.text))
                    self?.generateThumbnails(forJobIDs: thumbnailsForJobIDs)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.finishMetadataImport(tr("Metadata non letti: {0}", error))
                    self?.generateThumbnails(forJobIDs: thumbnailsForJobIDs)
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
    func generateThumbnails(forJobIDs jobIDs: [UUID]) {
        guard let store, !jobIDs.isEmpty else { return }
        runThumbnails(clips: jobIDs.flatMap { (try? store.clips(forJobID: $0)) ?? [] }, regenerate: false)
    }

    /// Crea (o ritenta) le anteprime dei clip mostrati.
    func generateThumbnailsForSelection(regenerate: Bool) {
        runThumbnails(clips: clips, regenerate: regenerate)
    }

    private func runThumbnails(clips: [ClipRecord], regenerate: Bool) {
        guard let store, !clips.isEmpty, !isGeneratingThumbnails else { return }
        let tools = ThumbnailTools()
        guard tools.art != nil || tools.ffmpeg != nil else {
            thumbnailStatus = tr("Né ffmpeg né art-cmd sono installati: anteprime non create (vedi l'avviso in alto per installarli).")
            return
        }
        isGeneratingThumbnails = true
        thumbnailStatus = tr("Creazione anteprime…")
        let cache = thumbnails
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let summary = try ThumbnailGenerator.generate(for: clips, store: store, tools: tools, cache: cache, regenerate: regenerate) { done, total in
                    DispatchQueue.main.async {
                        self?.thumbnailStatus = tr("Creazione anteprime… {0}/{1}", done, total)
                        self?.thumbnailRevision += 1
                    }
                }
                DispatchQueue.main.async { self?.finishThumbnails(tr("Anteprime: {0}", summary.text)) }
            } catch {
                DispatchQueue.main.async { self?.finishThumbnails(tr("Anteprime non create: {0}", error)) }
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
        guard let store else { return tr("Database dei progetti non disponibile.") }
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
