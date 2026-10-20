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
            Button("Nuovo progetto") { request = .newProject }
            Button("Rinomina") {
                if let p = projects.selectedProject { request = .renameProject(p.name) }
            }
            .disabled(projects.selectedProject == nil)
            Button("Elimina") { confirmDelete = true }
                .disabled(projects.selectedProject == nil)
        }
        .padding(10)
        .alert("Eliminare il progetto «\(projects.selectedProject?.name ?? "")»?", isPresented: $confirmDelete) {
            Button("Elimina", role: .destructive) { projects.deleteProject() }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Vengono eliminati solo i record nel programma (giorni, bin, offload, clip). I file già copiati sui dischi NON vengono toccati.")
        }
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

    private func deleteMessage() -> String {
        guard let t = deleteTarget, let impact = projects.deletionImpact(id: t.id) else { return "" }
        return "Verranno eliminati dal programma \(impact.bins) bin, \(impact.offloads) offload e \(impact.clips) file registrati. I file sui dischi NON vengono toccati."
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

struct ClipTableView: View {
    @ObservedObject var projects: ProjectsViewModel
    @AppStorage("clipColumns") private var columnsSetting = ClipColumns.defaultVisibleIDs.joined(separator: ",")
    @State private var sortColumnID = "name"
    @State private var ascending = true

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
        let col = ClipColumns.column(id: sortColumnID) ?? ClipColumns.all[0]
        return ClipColumns.sorted(projects.clips, by: col, ascending: ascending)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(projects.clips.count) \(projects.showAllFiles ? "file" : "clip")")
                    .font(.callout)
                Toggle("Mostra anche i file non video (XML, sidecar…)",
                       isOn: Binding(get: { projects.showAllFiles }, set: { projects.setShowAllFiles($0) }))
                    .toggleStyle(.checkbox)
                Spacer()
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

    private func cell(_ col: ClipColumn, _ clip: ClipRecord) -> some View {
        let text = ClipColumns.value(col, of: clip)
        return Text(text)
            .lineLimit(1)
            .truncationMode(.middle)
            .font(col.id == "hash" ? .system(.body, design: .monospaced) : .body)
            .foregroundStyle(color(col, clip, text))
            .frame(width: col.width, alignment: .leading)
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
#endif
