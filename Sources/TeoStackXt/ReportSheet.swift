#if canImport(SwiftUI)
import SwiftUI
import AppKit
import TeoStackCore

extension Notification.Name {
    static let exportReport = Notification.Name("TeoStackXtExportReport")
}

/// Finestra «Esporta report»: sceglie quali dei 5 report creare (ognuno è un PDF separato) e la cartella di destinazione.
struct ReportSheet: View {
    @ObservedObject var projects: ProjectsViewModel
    let close: () -> Void

    @AppStorage("reportOperator") private var operatorName = ""
    /// Stessa scelta del menu «Colonne» del tab Clip.
    @AppStorage("clipColumns") private var columnsSetting = ClipColumns.defaultVisibleIDs.joined(separator: ",")
    @State private var projectName = ""
    @State private var notes = ""
    @State private var kinds: Set<ReportKind> = Set(ReportKind.allCases)
    @State private var working = false
    @State private var message: String?
    @State private var messageIsError = false
    @State private var revealURLs: [URL] = []

    private var scopeText: String {
        guard let id = projects.selectedNodeID, let node = projects.node(id) else { return "—" }
        return node.name
    }

    private var scopeIsBin: Bool {
        guard let id = projects.selectedNodeID, let node = projects.node(id) else { return true }
        return node.kind == .bin
    }

    private var selectedColumnIDs: [String] {
        let wanted = Set(columnsSetting.split(separator: ",").map(String.init))
        return ReportColumnChoice.available.map(\.id).filter { wanted.contains($0) }
    }

    private func columnBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { selectedColumnIDs.contains(id) },
                set: { on in
                    var ids = Set(columnsSetting.split(separator: ",").map(String.init))
                    if on { ids.insert(id) } else { ids.remove(id) }
                    columnsSetting = ClipColumns.all.map(\.id).filter { ids.contains($0) }.joined(separator: ",")
                })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Esporta report (PDF)")).font(.title3.bold())
            Text(scopeIsBin ? tr("Ambito: {0}", scopeText) : tr("Ambito: {0} (tutti i bin contenuti)", scopeText)).font(.callout).foregroundStyle(.secondary)

            HStack {
                TextField(tr("Nome progetto"), text: $projectName).textFieldStyle(.roundedBorder)
                TextField(tr("Operatore"), text: $operatorName).textFieldStyle(.roundedBorder)
            }
            GroupBox(tr("Report da creare (un PDF per ciascuno)")) {
                VStack(alignment: .leading) {
                    ForEach(ReportKind.allCases) { kind in
                        Toggle(kind.title, isOn: Binding(
                            get: { kinds.contains(kind) },
                            set: { on in if on { kinds.insert(kind) } else { kinds.remove(kind) } }))
                            .toggleStyle(.checkbox)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox(tr("Colonne dei report Clips e Thumbnail (stesse del tab Clip)")) {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 4) {
                        ForEach(ReportColumnChoice.available) { c in
                            Toggle(c.localizedTitle, isOn: columnBinding(c.id)).toggleStyle(.checkbox)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: 140)
            }
            Text(tr("«Name» è sempre presente. Shooting Day, Volume e Contact Print hanno un formato fisso. Le anteprime compaiono se sono già state generate (tab Clip)."))
                .font(.caption).foregroundStyle(.secondary)

            if let message {
                HStack {
                    Text(message).font(.callout).foregroundStyle(messageIsError ? Color.red : Color.green)
                        .fixedSize(horizontal: false, vertical: true)
                    if !revealURLs.isEmpty {
                        Button(tr("Mostra nel Finder")) { NSWorkspace.shared.activateFileViewerSelecting(revealURLs) }
                    }
                }
            }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button(tr("Chiudi")) { close() }.keyboardShortcut(.cancelAction)
                Button(tr("Esporta PDF…")) { export() }
                    .disabled(working || kinds.isEmpty || projectName.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { projectName = projects.selectedProject?.name ?? "" }
    }

    private func export() {
        guard let store = projects.store, let pid = projects.selectedProjectID, let nid = projects.selectedNodeID else { return }
        let panel = NSOpenPanel()
        panel.title = tr("Cartella in cui salvare i report")
        panel.prompt = tr("Salva qui")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        let options = ReportOptions(projectName: projectName.trimmingCharacters(in: .whitespaces), operatorName: operatorName, notes: notes,
                                    columnIDs: selectedColumnIDs)
        let chosen = ReportKind.allCases.filter { kinds.contains($0) }
        let thumbnails = projects.thumbnails
        working = true
        message = nil
        revealURLs = []
        DispatchQueue.global(qos: .userInitiated).async {
            var saved: [URL] = []
            var failures: [String] = []
            for kind in chosen {
                do {
                    let output = try ReportGenerator.generate(kind, store: store, projectID: pid, nodeID: nid, options: options, thumbnails: thumbnails)
                    let url = uniqueURL(folder.appendingPathComponent(output.fileName))
                    try output.data.write(to: url, options: .atomic)
                    saved.append(url)
                } catch {
                    failures.append("\(kind.title): \(error)")
                }
            }
            DispatchQueue.main.async {
                working = false
                revealURLs = saved
                if failures.isEmpty {
                    message = tr("Salvati {0} report in {1}", saved.count, folder.path)
                    messageIsError = false
                } else {
                    message = tr("Errori: {0}", failures.joined(separator: " · ")) + (saved.isEmpty ? "" : " — " + tr("salvati {0} report in {1}", saved.count, folder.path))
                    messageIsError = true
                }
            }
        }
    }

    /// Non sovrascrive mai un file esistente: aggiunge « 2», « 3»… al nome.
    private func uniqueURL(_ url: URL) -> URL {
        var candidate = url
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let base = url.deletingPathExtension().lastPathComponent
            candidate = url.deletingLastPathComponent().appendingPathComponent("\(base) \(n).pdf")
            n += 1
        }
        return candidate
    }
}
#endif
