#if canImport(SwiftUI)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TeoStackCore

extension Notification.Name {
    static let exportReport = Notification.Name("TeoStackXtExportReport")
}

/// Finestra «Esporta report»: sezioni, campi (progetto, operatore, note) e salvataggio del PDF.
struct ReportSheet: View {
    @ObservedObject var projects: ProjectsViewModel
    let close: () -> Void

    @AppStorage("reportOperator") private var operatorName = ""
    @AppStorage("clipColumns") private var clipColumnsSetting = ClipColumns.defaultVisibleIDs.joined(separator: ",")
    @State private var projectName = ""
    @State private var notes = ""
    @State private var sections: Set<ReportSection> = [.shootingDay, .clips, .volume]
    @State private var working = false
    @State private var message: String?
    @State private var messageIsError = false
    @State private var revealURL: URL?

    private var scopeText: String {
        guard let tree = projects.tree, let id = projects.selectedNodeID, let node = projects.node(id) else { return "—" }
        return ReportBuilder.scopeTitle(scope: node, tree: tree)
    }

    private var clipColumnIDs: [String] {
        let wanted = Set(clipColumnsSetting.split(separator: ",").map(String.init))
        return ClipColumns.all.map(\.id).filter { wanted.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Esporta report (PDF)").font(.title3.bold())
            Text("Template Classic · Ambito: \(scopeText)").font(.callout).foregroundStyle(.secondary)

            reportContent

            if let message {
                HStack {
                    Text(message).font(.callout).foregroundStyle(messageIsError ? Color.red : Color.green)
                        .fixedSize(horizontal: false, vertical: true)
                    if let revealURL {
                        Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([revealURL]) }
                    }
                }
            }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Chiudi") { close() }.keyboardShortcut(.cancelAction)
                Button("Esporta PDF…") { export() }
                    .disabled(working || sections.isEmpty || projectName.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
        .onAppear { projectName = projects.selectedProject?.name ?? "" }
    }

    // MARK: Report

    private var reportContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Nome progetto", text: $projectName).textFieldStyle(.roundedBorder)
                TextField("Operatore", text: $operatorName).textFieldStyle(.roundedBorder)
            }
            GroupBox("Sezioni principali") {
                VStack(alignment: .leading) {
                    ForEach(ReportSection.allCases.filter { !$0.isOptionalSummary }) { sectionToggle($0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Riepiloghi opzionali") {
                VStack(alignment: .leading) {
                    ForEach(ReportSection.allCases.filter { $0.isOptionalSummary }) { sectionToggle($0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if sections.contains(.clips) {
                Text("Colonne della tabella Clips: quelle visibili nel tab Clip (\(clipColumnIDs.count)). Cambiale dal menu «Colonne».")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Note").font(.callout)
            TextEditor(text: $notes)
                .font(.body)
                .frame(height: 70)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
        }
    }

    private func sectionToggle(_ s: ReportSection) -> some View {
        Toggle(s.title, isOn: Binding(
            get: { sections.contains(s) },
            set: { on in if on { sections.insert(s) } else { sections.remove(s) } }))
            .toggleStyle(.checkbox)
    }

    private func export() {
        guard let store = projects.store, let pid = projects.selectedProjectID, let nid = projects.selectedNodeID else { return }
        var chosenSections = sections
        if !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { chosenSections.insert(.notes) }   // se ci sono note, vanno nel report
        let options = ReportOptions(projectName: projectName.trimmingCharacters(in: .whitespaces), operatorName: operatorName, notes: notes,
                                    sections: chosenSections, clipColumnIDs: clipColumnIDs)
        working = true
        message = nil
        revealURL = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let doc = try ReportBuilder.build(store: store, projectID: pid, nodeID: nid, options: options)
                let data = ReportPDF.render(doc, generatedAt: options.generatedAt)
                DispatchQueue.main.async { save(data, options: options) }
            } catch {
                DispatchQueue.main.async { fail("Impossibile creare il report: \(error)") }
            }
        }
    }

    private func save(_ data: Data, options: ReportOptions) {
        working = false
        let ext = "pdf"
        let panel = NSSavePanel()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        let safe = "\(options.projectName)_\(scopeText)".replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(safe)_\(formatter.string(from: options.generatedAt)).\(ext)"
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: ext) { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            message = "Report salvato: \(url.path)"
            messageIsError = false
            revealURL = url
        } catch {
            fail("Impossibile salvare il file: \(error)")
        }
    }

    private func fail(_ text: String) {
        working = false
        message = text
        messageIsError = true
    }
}
#endif
