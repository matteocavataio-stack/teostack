#if canImport(SwiftUI)
import SwiftUI
import AppKit
import TeoStackCore

// MARK: - Richieste di nome (finestre di dialogo)

enum NameRequest: Identifiable {
    case newProject
    case renameProject(String)
    case newDay(String)
    case newFolder
    case renameNode(id: Int64, name: String)

    var id: String {
        switch self {
        case .newProject: return "newProject"
        case .renameProject: return "renameProject"
        case .newDay: return "newDay"
        case .newFolder: return "newFolder"
        case .renameNode(let id, _): return "renameNode\(id)"
        }
    }

    var title: String {
        switch self {
        case .newProject: return tr("Nuovo progetto")
        case .renameProject: return tr("Rinomina progetto")
        case .newDay: return tr("Nuova cartella giorno")
        case .newFolder: return tr("Nuova cartella")
        case .renameNode: return tr("Rinomina")
        }
    }

    var initialName: String {
        switch self {
        case .newProject, .newFolder: return ""
        case .renameProject(let n), .newDay(let n): return n
        case .renameNode(_, let n): return n
        }
    }

    var hint: String? {
        switch self {
        case .newDay: return tr("Esempio: DAY01_20261016")
        case .newFolder: return tr("Per ordinare il progetto, per esempio CAM_A. I bin si creano da soli quando avvii un offload.")
        case .renameProject, .renameNode:
            return tr("Rinomina solo nel programma: le cartelle già create sui dischi non vengono rinominate.")
        case .newProject: return nil
        }
    }
}

struct NameSheet: View {
    let request: NameRequest
    let onSubmit: (String) -> String?
    let onClose: () -> Void

    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.title).font(.headline)
            TextField(tr("Nome"), text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit() }
            if let hint = request.hint {
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(tr("Annulla")) { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button(tr("OK")) { submit() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { text = request.initialName }
    }

    private func submit() {
        if let message = onSubmit(text) { error = message } else { onClose() }
    }
}

// MARK: - Barra progetto

/// Pulsante della barra in alto: icona sopra, testo sotto (come nella barra di Silverstack).
struct ToolbarButton: View {
    let title: String
    let symbol: String
    var destructive = false
    /// Scheda attiva (Offload / Clip): evidenziata.
    var isSelected = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 20)).frame(height: 24)
                Text(title).font(.caption).lineLimit(1)
            }
            .frame(minWidth: 82)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Color.accentColor.opacity(0.22) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(destructive ? Color.red : (isSelected ? Color.accentColor : Color.primary))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .opacity(isEnabled ? 1 : 0.35)
    }
}

struct ProjectBar: View {
    @ObservedObject var projects: ProjectsViewModel
    @Binding var request: NameRequest?
    @Binding var showReport: Bool
    @Binding var tab: MainTab
    @State private var confirmDelete = false

    private static func formattedDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Loc.language.locale
        f.dateStyle = .medium
        return f.string(from: date)
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(tr("Progetto")).font(.headline)
            if projects.projects.isEmpty {
                Text(tr("Nessun progetto: creane uno per iniziare")).foregroundStyle(.secondary)
            } else {
                Picker("", selection: Binding(get: { projects.selectedProjectID ?? -1 },
                                              set: { projects.selectProject($0 < 0 ? nil : $0) })) {
                    ForEach(projects.projects) { p in
                        Text(tr("{0}  ·  {1}  ·  {2} clip", p.name, Self.formattedDate(p.createdAt), p.clipCount)).tag(p.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 340)
                if let p = projects.selectedProject {
                    Text(tr("Creato il {0} · {1} clip", Self.formattedDate(p.createdAt), p.clipCount))
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
            Spacer()
            ToolbarButton(title: tr("Nuovo progetto"), symbol: "folder.badge.plus") { request = .newProject }
            ToolbarButton(title: tr("Rinomina"), symbol: "pencil") {
                if let p = projects.selectedProject { request = .renameProject(p.name) }
            }
            .disabled(projects.selectedProject == nil)
            ToolbarButton(title: tr("Elimina progetto"), symbol: "trash", destructive: true) { confirmDelete = true }
                .disabled(projects.selectedProject == nil)
                .help(tr("Elimina l'INTERO progetto. Per eliminare solo un giorno o un bin usa «Elimina selezione» nella barra laterale."))
            Divider().frame(height: 36)
            ToolbarButton(title: tr("Offload"), symbol: "externaldrive", isSelected: tab == .offload) { tab = .offload }
                .help(tr("Schermata di scarico: sorgente, destinazioni e avanzamento."))
            ToolbarButton(title: tr("Clip"), symbol: "film", isSelected: tab == .clips) { tab = .clips }
                .help(tr("Elenco dei clip del progetto con metadata, anteprime e riepilogo."))
            Divider().frame(height: 36)
            ToolbarButton(title: tr("Importa media"), symbol: "square.and.arrow.down") { projects.importMedia() }
                .disabled(projects.currentContainer == nil || projects.isImporting)
                .help(tr("Aggiunge clip al progetto senza scaricarli: i file restano dove sono (non vengono copiati né modificati). Servono a leggere i metadata e a esportare i report."))
            ToolbarButton(title: tr("Esporta report"), symbol: "doc.text") { showReport = true }
                .disabled(projects.selectedProject == nil)
        }
        .padding(10)
        .alert(tr("Eliminare il progetto «{0}»?", projects.selectedProject?.name ?? ""), isPresented: $confirmDelete) {
            Button(tr("Elimina"), role: .destructive) { projects.deleteProject() }
            Button(tr("Annulla"), role: .cancel) {}
        } message: {
            Text(projectDeleteMessage())
        }
    }

    private func projectDeleteMessage() -> String {
        if let lib = projects.tree, let impact = projects.deletionImpact(id: lib.id) {
            return tr("Verrà eliminato l'INTERO progetto dal programma ({0} bin, {1} offload, {2} file registrati). I file già copiati sui dischi NON vengono toccati. Per eliminare solo un giorno o un bin usa «Elimina selezione» nella barra laterale.", impact.bins, impact.offloads, impact.clips)
        }
        return tr("Verrà eliminato l'INTERO progetto dal programma. I file già copiati sui dischi NON vengono toccati. Per eliminare solo un giorno o un bin usa «Elimina selezione» nella barra laterale.")
    }
}

// MARK: - Sidebar ad albero

struct SidebarView: View {
    @ObservedObject var projects: ProjectsViewModel
    @Binding var request: NameRequest?
    @State private var deleteTarget: TreeNode?

    var body: some View {
        VStack(spacing: 0) {
            if let tree = projects.tree {
                List([tree], children: \.children,
                     selection: Binding(get: { projects.selectedNodeID }, set: { projects.selectNode($0) })) { node in
                    HStack(spacing: 6) {
                        Image(systemName: icon(node.kind))
                        Text(node.name).lineLimit(1)
                        if let verification = node.verification { VerificationDot(state: verification) }
                        Spacer()
                        Text("\(node.clipCount)").foregroundStyle(.secondary).monospacedDigit()
                    }
                    .contentShape(Rectangle())
                    .contextMenu { menu(for: node) }
                    .modifier(NodeDragDrop(node: node, projects: projects))
                }
            } else {
                Text(tr("Seleziona o crea un progetto"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Button(tr("+ Giorno")) { request = .newDay(projects.suggestedDayName) }
                    .disabled(projects.tree == nil)
                    .help(tr("Facoltativo: cartella con la data delle riprese"))
                Button(tr("+ Cartella")) { request = .newFolder }
                    .disabled(projects.currentContainer == nil)
                    .help(tr("Facoltativo: sottocartella per ordinare il progetto, dentro la cartella selezionata"))
                Spacer()
                Button(tr("Elimina selezione…"), role: .destructive) { deleteTarget = selectedDeletableNode }
                    .disabled(selectedDeletableNode == nil)
            }
            .padding(8)
            Divider()
            HStack {
                LanguageMenu()
                Spacer()
            }
            .padding(8)
        }
        .alert(tr("Eliminare «{0}»?", deleteTarget?.name ?? ""), isPresented: Binding(get: { deleteTarget != nil },
                                                                                set: { if !$0 { deleteTarget = nil } })) {
            Button(tr("Elimina"), role: .destructive) {
                if let t = deleteTarget { projects.deleteNode(id: t.id) }
                deleteTarget = nil
            }
            Button(tr("Annulla"), role: .cancel) { deleteTarget = nil }
        } message: {
            Text(deleteMessage())
        }
    }

    /// Il giorno o il bin selezionato (la Library non si elimina).
    private var selectedDeletableNode: TreeNode? {
        guard let id = projects.selectedNodeID, let n = projects.node(id), n.kind != .library else { return nil }
        return n
    }

    private func deleteMessage() -> String {
        guard let t = deleteTarget, let impact = projects.deletionImpact(id: t.id) else { return "" }
        if t.kind == .bin {
            return tr("Verrà eliminato SOLO il bin «{0}» ({1} offload, {2} file registrati). Il resto del progetto resta. I file sui dischi NON vengono toccati.", t.name, impact.offloads, impact.clips)
        }
        return tr("Verrà eliminata SOLO la cartella «{0}» con le sue sottocartelle e i suoi {1} bin ({2} offload, {3} file registrati). Il resto del progetto resta. I file sui dischi NON vengono toccati.", t.name, impact.bins, impact.offloads, impact.clips)
    }

    private func icon(_ kind: NodeKind) -> String {
        switch kind {
        case .library: return "books.vertical"
        case .day: return "calendar"
        case .folder: return "folder"
        case .bin: return "film"
        }
    }

    @ViewBuilder
    private func menu(for node: TreeNode) -> some View {
        switch node.kind {
        case .library:
            Button(tr("Nuova cartella giorno")) { request = .newDay(projects.suggestedDayName) }
            Button(tr("Nuova cartella")) { projects.selectNode(node.id); request = .newFolder }
        case .day, .folder:
            Button(tr("Nuova cartella")) { projects.selectNode(node.id); request = .newFolder }
            moveMenu(for: node)
            Button(tr("Rinomina")) { request = .renameNode(id: node.id, name: node.name) }
            Button(tr("Elimina…"), role: .destructive) { deleteTarget = node }
        case .bin:
            moveMenu(for: node)
            Button(tr("Rinomina")) { request = .renameNode(id: node.id, name: node.name) }
            Button(tr("Elimina…"), role: .destructive) { deleteTarget = node }
        }
    }

    @ViewBuilder
    private func moveMenu(for node: TreeNode) -> some View {
        let targets = projects.moveTargets(for: node.id)
        if !targets.isEmpty {
            Menu(tr("Sposta in")) {
                ForEach(targets) { t in
                    Button(t.label) { projects.moveNode(id: node.id, toParent: t.id) }
                }
            }
        }
    }
}

/// Pallino accanto al bin: verde = verificato, rosso = non verificato, arancione = offload in corso.
struct VerificationDot: View {
    let state: BinVerification

    var body: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 9))
            .foregroundStyle(color)
            .help(text)
    }

    private var color: Color {
        switch state {
        case .verified: return .green
        case .notVerified: return .red
        case .inProgress: return .orange
        }
    }

    private var text: String {
        switch state {
        case .verified: return tr("Verificato: tutti i file sono stati riletti dal disco con XXH64 identico alla sorgente")
        case .notVerified: return tr("Non verificato: ci sono file con problemi, un offload annullato o file importati senza copia")
        case .inProgress: return tr("Offload in corso")
        }
    }
}

/// Trascinando un giorno, una cartella o un bin su una cartella (o sulla Library) lo si sposta lì dentro.
struct NodeDragDrop: ViewModifier {
    let node: TreeNode
    @ObservedObject var projects: ProjectsViewModel
    private static let prefix = "teostack-node:"

    func body(content: Content) -> some View {
        content
            .draggable(node.kind == .library ? "" : "\(Self.prefix)\(node.id)")
            .dropDestination(for: String.self) { items, _ in
                guard node.kind != .bin, let raw = items.first, raw.hasPrefix(Self.prefix),
                      let id = Int64(raw.dropFirst(Self.prefix.count)) else { return false }
                projects.moveNode(id: id, toParent: node.id)
                return true
            }
    }
}

// MARK: - Tabella clip con colonne configurabili

/// Anteprime già lette dal disco (evita di rileggere il JPEG a ogni ridisegno).
enum ThumbnailImageStore {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(at url: URL) -> NSImage? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let key = "\(url.path)|\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

struct ThumbnailCell: View {
    let clip: ClipRecord
    let cache: ThumbnailCache
    let revision: Int

    var body: some View {
        Group {
            if let image = ThumbnailImageStore.image(at: cache.imageURL(clipID: clip.id)) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15))
                    Image(systemName: clip.isAudio ? "waveform" : (cache.failureReason(clipID: clip.id) == nil ? "photo" : "exclamationmark.triangle"))
                        .foregroundStyle(.secondary)
                }
                .help(clip.isAudio ? tr("Clip audio: nessuna anteprima.") : (cache.failureReason(clipID: clip.id) ?? tr("Anteprima non ancora creata")))
            }
        }
        .frame(width: 88, height: 50)
        .id(revision)
    }
}

/// Pannello con il primo fotogramma grande e i dati principali del clip selezionato.
struct ClipPreviewPanel: View {
    let clip: ClipRecord
    @ObservedObject var projects: ProjectsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(clip.name).font(.headline).lineLimit(2)
            if clip.isAudio {
                Text(tr("Clip audio: nessuna anteprima.")).font(.callout).foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
            } else if let image = ThumbnailImageStore.image(at: projects.thumbnails.imageURL(clipID: clip.id)) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(Color.black)
                Text(tr("Primo fotogramma")).font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(projects.thumbnails.failureReason(clipID: clip.id) ?? tr("Anteprima non ancora creata."))
                        .font(.callout).foregroundStyle(projects.thumbnails.failureReason(clipID: clip.id) == nil ? Color.secondary : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Button(tr("Crea anteprime")) { projects.generateThumbnailsForSelection(regenerate: false) }
                        .disabled(projects.isGeneratingThumbnails)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
            }
            Divider()
            ForEach(["camera", "lens", "iso", "whiteBalance", "ndFilter", "sensorFPS", "shutter", "resolution", "codec", "timecode", "duration", "audioCodec", "audioChannels", "audioSampleRate", "audioBitDepth", "container", "gamma", "aperture", "tStop", "shutterAngle", "frameCount"], id: \.self) { id in
                if let col = ClipColumns.column(id: id) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(col.localizedTitle).font(.caption).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
                        Text(ClipColumns.value(col, of: clip)).font(.callout).textSelection(.enabled)
                    }
                }
            }
            let raw = clip.metadata.filter { $0.key.hasPrefix(ClipMetadata.rawPrefix) }
            if !raw.isEmpty {
                DisclosureGroup(tr("Tutti i tag letti ({0})", raw.count)) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(raw.keys.sorted(), id: \.self) { key in
                                Text("\(key.dropFirst(ClipMetadata.rawPrefix.count)): \(raw[key] ?? "")")
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
                .font(.callout)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .id(projects.thumbnailRevision)
    }
}

struct ClipTableView: View {
    @ObservedObject var projects: ProjectsViewModel
    @AppStorage("clipColumns") private var columnsSetting = ClipColumns.defaultVisibleIDs.joined(separator: ",")
    @AppStorage("clipPreviewColumnAdded") private var previewColumnAdded = false
    @State private var sortColumnID = "name"
    @State private var ascending = true
    @State private var selectedClipID: Int64?

    private var visibleColumns: [ClipColumn] {
        let wanted = Set(columnsSetting.split(separator: ",").map(String.init))
        return ClipColumns.all.filter { wanted.contains($0.id) }
    }

    private func isVisible(_ column: ClipColumn) -> Bool { visibleColumns.contains(column) }

    private func toggle(_ column: ClipColumn) {
        var ids = Set(visibleColumns.map(\.id))
        if ids.contains(column.id) { ids.remove(column.id) } else { ids.insert(column.id) }
        if ids.isEmpty { ids = ["name"] }
        columnsSetting = ClipColumns.all.map(\.id).filter { ids.contains($0) }.joined(separator: ",")
    }

    private var rows: [ClipRecord] {
        let col = ClipColumns.column(id: sortColumnID) ?? ClipColumns.all[1]
        return ClipColumns.sorted(projects.clips, by: col, ascending: ascending)
    }

    private var selectedClip: ClipRecord? {
        projects.clips.first { $0.id == selectedClipID }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            tableArea
            if let clip = selectedClip {
                Divider()
                ClipPreviewPanel(clip: clip, projects: projects)
                    .frame(width: 360)
            }
        }
        .onAppear {
            // una tantum: chi aveva già scelto le colonne trova comunque la colonna Anteprima
            if !previewColumnAdded {
                previewColumnAdded = true
                if let preview = ClipColumns.column(id: "preview"), !isVisible(preview) { toggle(preview) }
            }
        }
    }

    private var tableArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(projects.clips.count) \(projects.showAllFiles ? tr("file") : tr("clip"))")
                    .font(.callout)
                Toggle(tr("Mostra anche i file non video (XML, sidecar…)"),
                       isOn: Binding(get: { projects.showAllFiles }, set: { projects.setShowAllFiles($0) }))
                    .toggleStyle(.checkbox)
                Spacer()
                Button(tr("Crea anteprime")) { projects.generateThumbnailsForSelection(regenerate: false) }
                    .disabled(projects.isGeneratingThumbnails || projects.clips.isEmpty)
                    .help(tr("Crea l'anteprima del primo fotogramma dei clip che ne sono privi (dalla copia verificata sul disco di destinazione)."))
                Button(tr("Leggi metadata")) { projects.readMetadataForSelection() }
                    .disabled(projects.isReadingMetadata || projects.clips.isEmpty)
                    .help(tr("Rilegge i metadata dei clip mostrati con ExifTool e art-cmd (dalla copia verificata sul disco di destinazione)."))
                Button(tr("Importa log…")) { projects.importSidecarLog() }
                    .disabled(projects.clips.isEmpty)
                    .help(tr("Importa un log esterno (ALE, CSV, XML) con scena, take, tape e note, e lo abbina ai clip mostrati."))
                Menu(tr("Esporta metadata")) {
                    ForEach(MetadataExporter.Format.allCases) { f in
                        Button(f.rawValue.uppercased()) { projects.exportMetadata(f) }
                    }
                }
                .disabled(projects.clips.isEmpty)
                .fixedSize()
                .help(tr("Salva i metadata dei clip mostrati in JSON, CSV o ALE (Avid). Ogni riga include l'XXH64 del file."))
                Menu(tr("Colonne")) {
                    Section(tr("Dati dell'offload")) {
                        ForEach(ClipColumns.all.filter { !$0.isMetadata }) { c in
                            Toggle(c.localizedTitle, isOn: Binding(get: { isVisible(c) }, set: { _ in toggle(c) }))
                        }
                    }
                    Section(tr("Metadata camera (N/D se non letti)")) {
                        ForEach(ClipColumns.all.filter { $0.isMetadata }) { c in
                            Toggle(c.localizedTitle, isOn: Binding(get: { isVisible(c) }, set: { _ in toggle(c) }))
                        }
                    }
                }
                .fixedSize()
            }
            if let status = projects.metadataStatus {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            if let status = projects.thumbnailStatus {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Text(tr("ExifTool dà camera, firmware, risoluzione, durata, FPS del file, timecode, data di ripresa dei clip ARRI. art-cmd (ARRI Reference Tool) dà ISO, WB, lente, ND, look, sensor FPS, scena/take/reel, serial: sono i valori del primo fotogramma del clip. Per MPG, WAV/BWF, LRF, MP4, ProRes e gli altri formati legge ffprobe: codec, risoluzione, FPS, durata, audio, e timecode/data/camera solo se scritti nel file. L'anteprima è il primo fotogramma (ARRI: art-cmd con look incorporato; altri video: ffmpeg). Se un valore non è leggibile mostra N/D."))
                .font(.caption2)
                .foregroundStyle(.secondary)
            if projects.clips.isEmpty {
                Text(tr("Nessuna clip: esegui un offload in un bin di questo progetto."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section(header: header) {
                            ForEach(rows) { clip in
                                HStack(spacing: 0) {
                                    ForEach(visibleColumns) { col in
                                        cell(col, clip)
                                    }
                                }
                                .padding(.vertical, 3)
                                .background(clip.id == selectedClipID ? Color.accentColor.opacity(0.18) : Color.clear)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedClipID = clip.id }
                                Divider()
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
    }

    private var header: some View {
        HStack(spacing: 0) {
            ForEach(visibleColumns) { col in
                Button {
                    guard col.id != "preview" else { return }
                    if sortColumnID == col.id { ascending.toggle() } else { sortColumnID = col.id; ascending = true }
                } label: {
                    HStack(spacing: 2) {
                        Text(col.localizedTitle).bold()
                        if sortColumnID == col.id { Image(systemName: ascending ? "chevron.up" : "chevron.down").font(.caption2) }
                        Spacer(minLength: 0)
                    }
                    .frame(width: col.width, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func cell(_ col: ClipColumn, _ clip: ClipRecord) -> some View {
        if col.id == "preview" {
            ThumbnailCell(clip: clip, cache: projects.thumbnails, revision: projects.thumbnailRevision)
                .frame(width: col.width, alignment: .leading)
        } else {
            let text = ClipColumns.value(col, of: clip)
            Text(text)
                .lineLimit(1)
                .truncationMode(.middle)
                .font(col.id == "hash" ? .system(.body, design: .monospaced) : .body)
                .foregroundStyle(color(col, clip, text))
                .frame(width: col.width, alignment: .leading)
        }
    }

    private func color(_ col: ClipColumn, _ clip: ClipRecord, _ text: String) -> Color {
        if col.id == "status" {
            switch clip.status {
            case "ok": return .green
            case "mismatch", "error": return .red
            default: return .secondary
            }
        }
        return text == ClipColumns.notAvailable ? Color.secondary : Color.primary
    }
}

// MARK: - Cronologia del progetto (colonna a destra)

struct HistoryView: View {
    @ObservedObject var projects: ProjectsViewModel
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(tr("Cronologia")).font(.headline)
                Spacer()
                if let p = projects.selectedProject {
                    Text(p.name).foregroundStyle(.secondary).lineLimit(1)
                }
                Button(tr("Cancella…"), role: .destructive) { confirmClear = true }
                    .disabled(projects.history.isEmpty)
                    .help(tr("Cancella la cronologia di questo progetto"))
            }
            .padding(10)
            .alert(tr("Cancellare la cronologia di «{0}»?", projects.selectedProject?.name ?? ""), isPresented: $confirmClear) {
                Button(tr("Cancella"), role: .destructive) { projects.clearHistory() }
                Button(tr("Annulla"), role: .cancel) {}
            } message: {
                Text(tr("Verranno cancellate {0} voci di cronologia di questo progetto. Clip, offload e file sui dischi non vengono toccati. L'operazione non si può annullare.", projects.history.count))
            }
            Divider()
            if projects.selectedProject == nil {
                Text(tr("Seleziona un progetto"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if projects.history.isEmpty {
                Text(tr("Nessuna attività registrata"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(projects.history) { event in
                    HistoryRow(event: event)
                }
                .listStyle(.plain)
            }
        }
    }
}

struct HistoryRow: View {
    let event: HistoryEvent

    private static func formattedDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Loc.language.locale
        f.dateFormat = "dd/MM/yyyy HH:mm:ss"
        return f.string(from: date)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.formattedDate(event.date))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(event.title)
                    .font(.callout)
                    .foregroundStyle(event.severity == .error ? Color.red : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = event.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var color: Color {
        switch event.severity {
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        case .info: return .secondary
        }
    }

    private var icon: String {
        switch event.kind {
        case "projectCreated": return "folder.badge.plus"
        case "projectRenamed", "nodeRenamed": return "pencil"
        case "dayCreated": return "calendar.badge.plus"
        case "binCreated": return "film"
        case "nodeDeleted": return "trash"
        case "offloadStarted": return "arrow.right.circle"
        case "offloadResumed": return "arrow.clockwise"
        case "offloadCopyDone": return "doc.on.doc"
        case "offloadCompleted": return "checkmark.seal.fill"
        case "offloadProblems": return "exclamationmark.triangle.fill"
        case "offloadCancelled": return "xmark.circle"
        case "offloadNotStarted": return "exclamationmark.octagon.fill"
        default: return "circle"
        }
    }
}

// MARK: - Avviso programmi esterni mancanti

struct DependencyBanner: View {
    @ObservedObject var tools: ToolsViewModel
    @State private var expanded = false

    var body: some View {
        if !tools.missing.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(tr("Programmi esterni mancanti: {0}. I metadata che dipendono da essi resteranno {1}.",
                            tools.missing.map { $0.tool.displayName }.joined(separator: ", "), ClipColumns.notAvailable))
                        .font(.callout.bold())
                    Spacer()
                    Button(expanded ? tr("Nascondi istruzioni") : tr("Come installarli")) { expanded.toggle() }
                    if tools.missing.contains(where: { $0.tool == .artCmd }) {
                        Button(tr("Scegli art-cmd…")) { tools.choosePath(for: .artCmd) }
                    }
                    Button(tr("Ricontrolla")) { tools.recheck() }
                }
                if expanded {
                    ForEach(tools.missing) { status in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(status.tool.displayName): \(status.tool.purpose)").font(.caption.bold())
                            Text(status.tool.installInstructions)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12)))
                        }
                    }
                    Text(tr("Si incolla nel Terminale, una riga alla volta. Poi premi «Ricontrolla»."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(Color.orange.opacity(0.15))
        }
    }
}
#endif
