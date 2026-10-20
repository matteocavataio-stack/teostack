#if canImport(SwiftUI)
import SwiftUI
import AppKit
import TeoStackCore

// MARK: - Richieste di nome (finestre di dialogo)

enum NameRequest: Identifiable {
    case newProject
    case renameProject(String)
    case newDay(String)
    case newBin(String)
    case renameNode(id: Int64, name: String)

    var id: String {
        switch self {
        case .newProject: return "newProject"
        case .renameProject: return "renameProject"
        case .newDay: return "newDay"
        case .newBin: return "newBin"
        case .renameNode(let id, _): return "renameNode\(id)"
        }
    }

    var title: String {
        switch self {
        case .newProject: return "Nuovo progetto"
        case .renameProject: return "Rinomina progetto"
        case .newDay: return "Nuova cartella giorno"
        case .newBin: return "Nuovo bin (camera / roll)"
        case .renameNode: return "Rinomina"
        }
    }

    var initialName: String {
        switch self {
        case .newProject, .newBin: return ""
        case .renameProject(let n), .newDay(let n): return n
        case .renameNode(_, let n): return n
        }
    }

    var hint: String? {
        switch self {
        case .newDay: return "Esempio: DAY01_20261016"
        case .newBin: return "Esempio: A_0001_1DET"
        case .renameProject, .renameNode:
            return "Rinomina solo nel programma: le cartelle già create sui dischi non vengono rinominate."
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
            TextField("Nome", text: $text)
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
                Button("Annulla") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("OK") { submit() }
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

struct ProjectBar: View {
    @ObservedObject var projects: ProjectsViewModel
    @Binding var request: NameRequest?
    @Binding var showReport: Bool
    @State private var confirmDelete = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateStyle = .medium
        return f
    }()

    var body: some View {
        HStack(spacing: 12) {
            Text("Progetto").font(.headline)
            if projects.projects.isEmpty {
                Text("Nessun progetto: creane uno per iniziare").foregroundStyle(.secondary)
            } else {
                Picker("", selection: Binding(get: { projects.selectedProjectID ?? -1 },
                                              set: { projects.selectProject($0 < 0 ? nil : $0) })) {
                    ForEach(projects.projects) { p in
                        Text("\(p.name)  ·  \(Self.dateFormatter.string(from: p.createdAt))  ·  \(p.clipCount) clip").tag(p.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 460)
                if let p = projects.selectedProject {
                    Text("Creato il \(Self.dateFormatter.string(from: p.createdAt)) · \(p.clipCount) clip")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
            Spacer()
            Button("Esporta report…") { showReport = true }
                .disabled(projects.selectedProject == nil)
            Button("Nuovo progetto") { request = .newProject }
            Button("Rinomina") {
                if let p = projects.selectedProject { request = .renameProject(p.name) }
            }
            .disabled(projects.selectedProject == nil)
            Button("Elimina progetto…", role: .destructive) { confirmDelete = true }
                .disabled(projects.selectedProject == nil)
                .help("Elimina l'INTERO progetto. Per eliminare solo un giorno o un bin usa «Elimina selezione» nella barra laterale.")
        }
        .padding(10)
        .alert("Eliminare il progetto «\(projects.selectedProject?.name ?? "")»?", isPresented: $confirmDelete) {
            Button("Elimina", role: .destructive) { projects.deleteProject() }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text(projectDeleteMessage())
        }
    }

    private func projectDeleteMessage() -> String {
        var text = "Verrà eliminato l'INTERO progetto dal programma"
        if let lib = projects.tree, let impact = projects.deletionImpact(id: lib.id) {
            text += " (\(impact.bins) bin, \(impact.offloads) offload, \(impact.clips) file registrati)"
        }
        return text + ". I file già copiati sui dischi NON vengono toccati. Per eliminare solo un giorno o un bin usa «Elimina selezione» nella barra laterale."
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
                        Spacer()
                        Text("\(node.clipCount)").foregroundStyle(.secondary).monospacedDigit()
                    }
                    .contextMenu { menu(for: node) }
                }
            } else {
                Text("Seleziona o crea un progetto")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Button("+ Giorno") { request = .newDay(projects.suggestedDayName) }
                    .disabled(projects.tree == nil)
                Button("+ Bin") { request = .newBin("") }
                    .disabled(projects.currentDay == nil)
                Spacer()
                Button("Elimina selezione…", role: .destructive) { deleteTarget = selectedDeletableNode }
                    .disabled(selectedDeletableNode == nil)
            }
            .padding(8)
        }
        .alert("Eliminare «\(deleteTarget?.name ?? "")»?", isPresented: Binding(get: { deleteTarget != nil },
                                                                                set: { if !$0 { deleteTarget = nil } })) {
            Button("Elimina", role: .destructive) {
                if let t = deleteTarget { projects.deleteNode(id: t.id) }
                deleteTarget = nil
            }
            Button("Annulla", role: .cancel) { deleteTarget = nil }
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
        let what = t.kind == .day ? "la cartella giorno «\(t.name)» con i suoi \(impact.bins) bin" : "il bin «\(t.name)»"
        return "Verrà eliminato SOLO \(what) (\(impact.offloads) offload, \(impact.clips) file registrati). Il resto del progetto resta. I file sui dischi NON vengono toccati."
    }

    private func icon(_ kind: NodeKind) -> String {
        switch kind {
        case .library: return "books.vertical"
        case .day: return "calendar"
        case .bin: return "film"
        }
    }

    @ViewBuilder
    private func menu(for node: TreeNode) -> some View {
        switch node.kind {
        case .library:
            Button("Nuova cartella giorno") { request = .newDay(projects.suggestedDayName) }
        case .day:
            Button("Nuovo bin") { projects.selectNode(node.id); request = .newBin("") }
            Button("Rinomina") { request = .renameNode(id: node.id, name: node.name) }
            Button("Elimina…", role: .destructive) { deleteTarget = node }
        case .bin:
            Button("Rinomina") { request = .renameNode(id: node.id, name: node.name) }
            Button("Elimina…", role: .destructive) { deleteTarget = node }
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
                    Image(systemName: cache.failureReason(clipID: clip.id) == nil ? "photo" : "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
                .help(cache.failureReason(clipID: clip.id) ?? "Anteprima non ancora creata")
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
            if let image = ThumbnailImageStore.image(at: projects.thumbnails.imageURL(clipID: clip.id)) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(Color.black)
                Text("Primo fotogramma").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(projects.thumbnails.failureReason(clipID: clip.id) ?? "Anteprima non ancora creata.")
                        .font(.callout).foregroundStyle(projects.thumbnails.failureReason(clipID: clip.id) == nil ? Color.secondary : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Button("Crea anteprime") { projects.generateThumbnailsForSelection(regenerate: false) }
                        .disabled(projects.isGeneratingThumbnails)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
            }
            Divider()
            ForEach(["camera", "lens", "iso", "whiteBalance", "ndFilter", "sensorFPS", "shutter", "resolution", "codec", "timecode", "duration"], id: \.self) { id in
                if let col = ClipColumns.column(id: id) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(col.title).font(.caption).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
                        Text(ClipColumns.value(col, of: clip)).font(.callout).textSelection(.enabled)
                    }
                }
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
                Text("\(projects.clips.count) \(projects.showAllFiles ? "file" : "clip")")
                    .font(.callout)
                Toggle("Mostra anche i file non video (XML, sidecar…)",
                       isOn: Binding(get: { projects.showAllFiles }, set: { projects.setShowAllFiles($0) }))
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Crea anteprime") { projects.generateThumbnailsForSelection(regenerate: false) }
                    .disabled(projects.isGeneratingThumbnails || projects.clips.isEmpty)
                    .help("Crea l'anteprima del primo fotogramma dei clip che ne sono privi (dalla copia verificata sul disco di destinazione).")
                Button("Leggi metadata") { projects.readMetadataForSelection() }
                    .disabled(projects.isReadingMetadata || projects.clips.isEmpty)
                    .help("Rilegge i metadata dei clip mostrati con ExifTool e art-cmd (dalla copia verificata sul disco di destinazione).")
                Menu("Colonne") {
                    Section("Dati dell'offload") {
                        ForEach(ClipColumns.all.filter { !$0.isMetadata }) { c in
                            Toggle(c.title, isOn: Binding(get: { isVisible(c) }, set: { _ in toggle(c) }))
                        }
                    }
                    Section("Metadata camera (N/D se non letti)") {
                        ForEach(ClipColumns.all.filter { $0.isMetadata }) { c in
                            Toggle(c.title, isOn: Binding(get: { isVisible(c) }, set: { _ in toggle(c) }))
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
            Text("ExifTool dà camera, firmware, risoluzione, durata, FPS del file, timecode, data di ripresa. art-cmd (ARRI Reference Tool) dà ISO, WB, lente, ND, look, sensor FPS, scena/take/reel, serial: sono i valori del primo fotogramma del clip. L'anteprima è il primo fotogramma (ARRI: art-cmd con look incorporato; altri video: ffmpeg). Se un valore non è leggibile mostra N/D.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if projects.clips.isEmpty {
                Text("Nessuna clip: esegui un offload in un bin di questo progetto.")
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
                        Text(col.title).bold()
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Cronologia").font(.headline)
                Spacer()
                if let p = projects.selectedProject {
                    Text(p.name).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(10)
            Divider()
            if projects.selectedProject == nil {
                Text("Seleziona un progetto")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if projects.history.isEmpty {
                Text("Nessuna attività registrata")
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

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "dd/MM/yyyy HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.formatter.string(from: event.date))
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
                    Text("Programmi esterni mancanti: " + tools.missing.map { $0.tool.displayName }.joined(separator: ", ")
                         + ". I metadata che dipendono da essi resteranno N/D.")
                        .font(.callout.bold())
                    Spacer()
                    Button(expanded ? "Nascondi istruzioni" : "Come installarli") { expanded.toggle() }
                    if tools.missing.contains(where: { $0.tool == .artCmd }) {
                        Button("Scegli art-cmd…") { tools.choosePath(for: .artCmd) }
                    }
                    Button("Ricontrolla") { tools.recheck() }
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
                    Text("Si incolla nel Terminale, una riga alla volta. Poi premi «Ricontrolla».")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(Color.orange.opacity(0.15))
        }
    }
}
#endif
