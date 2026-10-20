#if canImport(SwiftUI)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TeoStackCore

extension Notification.Name {
    static let exportReport = Notification.Name("TeoStackXtExportReport")
}

/// Finestra «Esporta report»: sezioni, campi (progetto, operatore, note), formato e salvataggio.
struct ReportSheet: View {
    @ObservedObject var projects: ProjectsViewModel
    let close: () -> Void

    @AppStorage("reportOperator") private var operatorName = ""
    @AppStorage("clipColumns") private var clipColumnsSetting = ClipColumns.defaultVisibleIDs.joined(separator: ",")
    @State private var projectName = ""
    @State private var notes = ""
    @State private var sections: Set<ReportSection> = [.shootingDay, .clips, .volume]
    @State private var format: ReportFormat = .pdf
    @State private var semicolon = true
    @State private var working = false
    @State private var message: String?
    @State private var messageIsError = false
    @State private var revealURL: URL?
    @State private var targets: [MHLTarget] = []
    @State private var selectedRoots: Set<String> = []

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
            Text("Esporta report").font(.title3.bold())
            Text("Template Classic · Ambito: \(scopeText)").font(.callout).foregroundStyle(.secondary)

            Picker("Formato", selection: $format) {
                ForEach(ReportFormat.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: format) { _ in
                message = nil
                if format == .ascmhl { loadTargets() }
            }

            if format == .ascmhl { mhlContent } else { reportContent }

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
                if format == .ascmhl {
                    Button("Scrivi ASC MHL") { writeMHL() }
                        .disabled(working || selectedRoots.isEmpty)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Esporta…") { export() }
                        .disabled(working || sections.isEmpty || projectName.trimmingCharacters(in: .whitespaces).isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 620)
        .onAppear {
            projectName = projects.selectedProject?.name ?? ""
            if format == .ascmhl { loadTargets() }
        }
    }

    // MARK: Report (PDF, HTML, CSV, XML, JSON)

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
            if sections.contains(.notes) || format == .pdf {
                Text("Note").font(.callout)
                TextEditor(text: $notes)
                    .font(.body)
                    .frame(height: 70)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
            }
            if format == .csv {
                Picker("Separatore CSV", selection: $semicolon) {
                    Text("Punto e virgola ;  (Excel italiano)").tag(true)
                    Text("Virgola ,").tag(false)
                }
                .pickerStyle(.radioGroup)
            }
            if format == .csv || format == .xml || format == .json {
                Text("In questo formato le dimensioni sono in byte e le durate in secondi.").font(.caption).foregroundStyle(.secondary)
            }
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
        let chosenFormat = format
        let delimiter: Character = semicolon ? ";" : ","
        working = true
        message = nil
        revealURL = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let doc = try ReportBuilder.build(store: store, projectID: pid, nodeID: nid, options: options)
                let data: Data
                switch chosenFormat {
                case .pdf: data = ReportPDF.render(doc, generatedAt: options.generatedAt)
                case .html: data = Data(ReportExporter.html(doc).utf8)
                case .csv: data = ReportExporter.csv(doc, delimiter: delimiter)
                case .xml: data = ReportExporter.xml(doc)
                case .json: data = try ReportExporter.json(doc)
                case .ascmhl: return
                }
                DispatchQueue.main.async { save(data, options: options) }
            } catch {
                DispatchQueue.main.async { fail("Impossibile creare il report: \(error)") }
            }
        }
    }

    private func save(_ data: Data, options: ReportOptions) {
        working = false
        guard let ext = format.fileExtension else { return }
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

    // MARK: ASC MHL

    private var mhlContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("La ASC MHL elenca i file VERIFICATI con il loro XXH64. Viene scritta nella cartella «ascmhl» dentro ogni cartella di destinazione scelta (la sorgente non viene mai toccata). Se la cartella «ascmhl» esiste già, viene aggiunta una nuova generazione senza modificare le precedenti.")
                .font(.callout)
            if targets.isEmpty {
                Text(working ? "Ricerca delle destinazioni…" : "Nessuna destinazione con file verificati nell'ambito selezionato.")
                    .foregroundStyle(.secondary)
            }
            ForEach(targets, id: \.root) { t in
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(t.root, isOn: Binding(
                        get: { selectedRoots.contains(t.root) },
                        set: { on in if on { selectedRoots.insert(t.root) } else { selectedRoots.remove(t.root) } }))
                        .toggleStyle(.checkbox)
                        .disabled(!t.rootExists || t.entries.isEmpty)
                    Text(detail(t)).font(.caption).foregroundStyle(t.rootExists ? Color.secondary : Color.red).padding(.leading, 20)
                }
            }
        }
    }

    private func detail(_ t: MHLTarget) -> String {
        if !t.rootExists { return "Cartella non raggiungibile (disco scollegato?)" }
        var text = "\(t.entries.count) file verificati"
        if !t.skipped.isEmpty { text += " · \(t.skipped.count) registrati OK ma non trovati o modificati: non inclusi" }
        if t.unlistedOnDisk > 0 { text += " · \(t.unlistedOnDisk) file nella cartella non verificati dall'app: non inclusi" }
        return text
    }

    private func loadTargets() {
        guard let store = projects.store, let nid = projects.selectedNodeID else { return }
        working = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = (try? MHLTargets.collect(store: store, nodeID: nid)) ?? []
            DispatchQueue.main.async {
                targets = found
                selectedRoots = Set(found.filter { $0.rootExists && !$0.entries.isEmpty }.map(\.root))
                working = false
            }
        }
    }

    private func writeMHL() {
        let chosen = targets.filter { selectedRoots.contains($0.root) }
        let author = operatorName
        let comment = "Progetto: \(projectName)"
        working = true
        message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            var lines: [String] = []
            var problem = false
            for t in chosen {
                do {
                    var options = MHLOptions()
                    options.author = author
                    options.comment = comment
                    let out = try ASCMHL.write(root: URL(fileURLWithPath: t.root), files: t.entries, options: options)
                    var line = "\(t.root): generazione \(out.generation), \(out.fileCount) file"
                    if !out.failedFiles.isEmpty { line += " — ATTENZIONE: \(out.failedFiles.count) file con hash diverso dalla generazione precedente"; problem = true }
                    lines.append(line)
                } catch {
                    lines.append("\(t.root): ERRORE \(error)")
                    problem = true
                }
            }
            DispatchQueue.main.async {
                working = false
                message = lines.joined(separator: "\n")
                messageIsError = problem
                revealURL = chosen.first.map { URL(fileURLWithPath: $0.root).appendingPathComponent(ASCMHL.folderName) }
                loadTargets()
            }
        }
    }
}
#endif
