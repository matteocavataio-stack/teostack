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
    /// Colonne dei report: scelta propria della finestra (non cambia più il tab Clip), così un profilo non tocca la tabella.
    @AppStorage("reportColumns") private var columnsSetting = ""
    /// Per la prima volta: si parte dalle colonne del tab Clip.
    @AppStorage("clipColumns") private var clipColumnsSetting = ClipColumns.defaultVisibleIDs.joined(separator: ",")
    @AppStorage("reportPresetID") private var lastPresetID = ""
    @State private var presets: [ReportPreset] = []
    @State private var selectedPresetID: UUID?
    private enum NameMode { case save, rename }
    @State private var nameMode: NameMode?
    @State private var nameInput = ""
    @State private var confirmDeletePreset = false
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
            Text(tr("Esporta report (PDF)")).appFont(.title3, bold: true)
            Text(scopeIsBin ? tr("Ambito: {0}", scopeText) : tr("Ambito: {0} (tutti i bin contenuti)", scopeText)).appFont(.callout).foregroundStyle(.secondary)

            presetBar
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
            GroupBox(tr("Colonne dei report Clips e Thumbnail")) {
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
                .appFont(.caption).foregroundStyle(.secondary)

            if let message {
                HStack {
                    Text(message).appFont(.callout).foregroundStyle(messageIsError ? Color.red : Color.green)
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
        .onAppear {
            projectName = projects.selectedProject?.name ?? ""
            if columnsSetting.isEmpty { columnsSetting = clipColumnsSetting }
            reloadPresets()
            // si riparte dall'ultimo profilo usato: non serve rifare le scelte ogni volta
            if let id = UUID(uuidString: lastPresetID), let preset = presets.first(where: { $0.id == id }) {
                selectedPresetID = id
                apply(preset)
            }
        }
        .onChange(of: selectedPresetID) { _, id in
            lastPresetID = id?.uuidString ?? ""
            if let id, let preset = presets.first(where: { $0.id == id }) { apply(preset) }
        }
        .alert(nameMode == .rename ? tr("Rinomina profilo") : tr("Nome del profilo"), isPresented: Binding(get: { nameMode != nil }, set: { if !$0 { nameMode = nil } })) {
            TextField(tr("Nome del profilo"), text: $nameInput)
            Button(tr("Salva")) { commitName() }
            Button(tr("Annulla"), role: .cancel) { nameMode = nil }
        }
        .alert(tr("Eliminare il profilo «{0}»?", currentPreset?.name ?? ""), isPresented: $confirmDeletePreset) {
            Button(tr("Elimina"), role: .destructive) { deleteCurrentPreset() }
            Button(tr("Annulla"), role: .cancel) {}
        }
    }

    // MARK: Profili

    private var currentPreset: ReportPreset? { presets.first { $0.id == selectedPresetID } }

    private var isModified: Bool {
        guard let p = currentPreset else { return false }
        return !p.matches(kinds: kinds, columnIDs: selectedColumnIDs, operatorName: operatorName)
    }

    private var presetBar: some View {
        HStack(spacing: 8) {
            Text(tr("Profilo")).appFont(.headline)
            Picker("", selection: $selectedPresetID) {
                Text(tr("Nessuno (scelte attuali)")).tag(UUID?.none)
                ForEach(presets) { p in Text(p.name).tag(Optional(p.id)) }
            }
            .labelsHidden()
            .frame(width: 220)
            if isModified { Text(tr("modificato")).appFont(.caption).foregroundStyle(Color.orange) }
            Spacer()
            Button(tr("Salva come…")) { nameInput = ""; nameMode = .save }
                .help(tr("Salva le scelte attuali (report, colonne, operatore) come nuovo profilo."))
            Button(tr("Aggiorna")) { updateCurrentPreset() }
                .disabled(currentPreset == nil || !isModified)
                .help(tr("Sostituisce le scelte del profilo selezionato con quelle attuali."))
            Menu(tr("Altro")) {
                Button(tr("Rinomina…")) { nameInput = currentPreset?.name ?? ""; nameMode = .rename }.disabled(currentPreset == nil)
                Button(tr("Elimina profilo…"), role: .destructive) { confirmDeletePreset = true }.disabled(currentPreset == nil)
                Divider()
                Button(tr("Esporta profili…")) { exportPresets() }.disabled(presets.isEmpty)
                Button(tr("Importa profili…")) { importPresets() }
            }
            .fixedSize()
        }
    }

    private func reloadPresets() { presets = ReportPresetStore().all() }

    private func apply(_ preset: ReportPreset) {
        kinds = Set(preset.resolvedKinds)
        columnsSetting = preset.resolvedColumnIDs.joined(separator: ",")
        operatorName = preset.operatorName
    }

    private func fail(_ error: Error) {
        message = "\(error)"
        messageIsError = true
        revealURLs = []
    }

    private func commitName() {
        let mode = nameMode
        nameMode = nil
        let store = ReportPresetStore()
        do {
            if mode == .rename, let id = selectedPresetID {
                try store.rename(id: id, to: nameInput)
            } else {
                let created = try store.create(name: nameInput, kinds: ReportKind.allCases.filter { kinds.contains($0) },
                                               columnIDs: selectedColumnIDs, operatorName: operatorName)
                reloadPresets()
                selectedPresetID = created.id
                message = tr("Profilo «{0}» salvato.", created.name)
                messageIsError = false
                revealURLs = []
            }
            reloadPresets()
        } catch { fail(error) }
    }

    private func updateCurrentPreset() {
        guard let id = selectedPresetID else { return }
        do {
            try ReportPresetStore().update(id: id, kinds: ReportKind.allCases.filter { kinds.contains($0) }, columnIDs: selectedColumnIDs, operatorName: operatorName)
            reloadPresets()
            message = tr("Profilo «{0}» aggiornato.", currentPreset?.name ?? "")
            messageIsError = false
            revealURLs = []
        } catch { fail(error) }
    }

    private func deleteCurrentPreset() {
        guard let id = selectedPresetID else { return }
        ReportPresetStore().delete(id: id)
        selectedPresetID = nil
        reloadPresets()
    }

    private func exportPresets() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "profili-report.json"
        panel.message = tr("Salva i profili in un file, per usarli su un altro Mac.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ReportPresetStore().exportData().write(to: url, options: .atomic)
            message = tr("Profili salvati in {0}", url.lastPathComponent)
            messageIsError = false
            revealURLs = [url]
        } catch { fail(error) }
    }

    private func importPresets() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = tr("Scegli un file di profili esportato da TeoStackPro.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let added = try ReportPresetStore().importData(try Data(contentsOf: url))
            reloadPresets()
            message = tr("Importati {0} profili.", added)
            messageIsError = false
            revealURLs = []
        } catch { fail(error) }
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
