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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Esporta report (PDF)").font(.title3.bold())
            Text("Ambito: \(scopeText)").font(.callout).foregroundStyle(.secondary)

            HStack {
                TextField("Nome progetto", text: $projectName).textFieldStyle(.roundedBorder)
                TextField("Operatore", text: $operatorName).textFieldStyle(.roundedBorder)
            }
            GroupBox("Report da creare (un PDF per ciascuno)") {
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
            Text("Le anteprime dei clip compaiono nei report se sono già state generate (tab Clip).")
                .font(.caption).foregroundStyle(.secondary)

            if let message {
                HStack {
                    Text(message).font(.callout).foregroundStyle(messageIsError ? Color.red : Color.green)
                        .fixedSize(horizontal: false, vertical: true)
                    if !revealURLs.isEmpty {
                        Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting(revealURLs) }
                    }
                }
            }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Chiudi") { close() }.keyboardShortcut(.cancelAction)
                Button("Esporta PDF…") { export() }
                    .disabled(working || kinds.isEmpty || projectName.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { projectName = projects.selectedProject?.name ?? "" }
    }

    private func export() {
        guard let store = projects.store, let pid = projects.selectedProjectID, let nid = projects.selectedNodeID else { return }
        let panel = NSOpenPanel()
        panel.title = "Cartella in cui salvare i report"
        panel.prompt = "Salva qui"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        let options = ReportOptions(projectName: projectName.trimmingCharacters(in: .whitespaces), operatorName: operatorName, notes: notes)
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
                    message = "Salvati \(saved.count) report in \(folder.path)"
                    messageIsError = false
                } else {
                    message = "Errori: " + failures.joined(separator: " · ") + (saved.isEmpty ? "" : " — salvati \(saved.count) report in \(folder.path)")
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
