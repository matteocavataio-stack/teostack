#if canImport(SwiftUI)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TeoStackCore

enum MainTab: String, CaseIterable, Identifiable {
    case offload = "Offload"
    case clips = "Clip"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .offload: return tr("Offload")
        case .clips: return tr("Clip")
        }
    }
}

struct ContentView: View {
    @StateObject private var app = AppModel()
    /// Cambiando lingua i testi si ridisegnano (.id sul contenuto: l'AppModel e un offload in corso non vengono toccati).
    @ObservedObject private var languageSettings = LanguageSettings.shared
    @State private var request: NameRequest?
    @State private var tab: MainTab = .offload
    @AppStorage("showHistory") private var showHistory = true
    @State private var showReport = false
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            ProjectBar(projects: app.projects, request: $request, showReport: $showReport, showSettings: $showSettings, tab: $tab)
                .sheet(isPresented: $showReport) {
                    ReportSheet(projects: app.projects) { showReport = false }
                }
            Divider()
            DependencyBanner(tools: app.tools)
            HSplitView {
                SidebarView(projects: app.projects, request: $request)
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 420)
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        Button(showHistory ? tr("Nascondi cronologia") : tr("Mostra cronologia")) { showHistory.toggle() }
                    }
                    .padding(8)
                    switch tab {
                    case .offload: OffloadView(vm: app.offload, projects: app.projects)
                    case .clips: ClipTableView(projects: app.projects)
                    }
                }
                .frame(minWidth: 760)
                if showHistory {
                    HistoryView(projects: app.projects)
                        .frame(minWidth: 260, idealWidth: 320, maxWidth: 520)
                }
            }
        }
        .id(languageSettings.language)
        .appAppearance()
        .frame(minWidth: 1280, minHeight: 760)
        .sheet(isPresented: $showSettings) {
            SettingsSheet { showSettings = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in showSettings = true }
        .onReceive(app.projects.$placement) { app.offload.placement = $0 }
        .onReceive(NotificationCenter.default.publisher(for: .exportReport)) { _ in
            if app.projects.selectedProject != nil { showReport = true }
        }
        .sheet(item: $request) { req in
            NameSheet(request: req, onSubmit: { submit(req, $0) }, onClose: { request = nil })
        }
        .alert(tr("Errore"), isPresented: Binding(get: { app.projects.errorMessage != nil || app.offload.errorMessage != nil },
                                              set: { if !$0 { app.projects.errorMessage = nil; app.offload.errorMessage = nil } })) {
            Button(tr("OK"), role: .cancel) {}
        } message: {
            Text([app.projects.errorMessage, app.offload.errorMessage].compactMap { $0 }.joined(separator: "\n"))
        }
    }

    private func submit(_ req: NameRequest, _ name: String) -> String? {
        switch req {
        case .newProject: return app.projects.createProject(name: name)
        case .renameProject: return app.projects.renameProject(name: name)
        case .newDay: return app.projects.createDay(name: name)
        case .newFolder: return app.projects.createFolder(name: name)
        case .renameNode(let id, _): return app.projects.renameNode(id: id, name: name)
        }
    }
}

struct OffloadView: View {
    @ObservedObject var vm: OffloadViewModel
    @ObservedObject var projects: ProjectsViewModel

    var body: some View {
        VStack(spacing: 0) {
            TargetBar(vm: vm, projects: projects)
            Divider()
            RecapPanel(projects: projects)
            SourcePanel(vm: vm)
                .frame(minHeight: 220)
            Divider()
            DestinationsPanel(vm: vm)
                .frame(minHeight: 230)
            Divider()
            ControlBar(vm: vm)
        }
    }
}

/// Mostra dove verrà creato il bin del progetto (cartella scelta nella barra laterale).
struct TargetBar: View {
    @ObservedObject var vm: OffloadViewModel
    @ObservedObject var projects: ProjectsViewModel

    var body: some View {
        HStack(spacing: 8) {
            Text(tr("Il bin verrà creato in:")).appFont(.headline)
            if let p = vm.placement {
                Text(p.displayPath).bold()
                if vm.sourceURL != nil, vm.binNameError == nil, let existing = projects.existingBin(named: vm.binName) {
                    let n = projects.offloadCount(binID: existing.id)
                    Text(tr("— il bin «{0}» esiste già ({1} offload): l'offload verrà aggiunto", existing.name, n))
                        .foregroundStyle(.orange).appFont(.callout)
                }
            } else {
                Text(tr("crea o seleziona un progetto (la cartella selezionata nella barra laterale ospiterà il bin)"))
                    .foregroundStyle(.red)
            }
            Spacer()
        }
        .padding(10)
    }
}

// MARK: - Riepilogo della cartella selezionata

/// Quanto c'è nella cartella selezionata (giorno, sottocartella, Library o bin), con le tabelle del «Shooting Day Report»:
/// panoramica clip, backup verificati, formati video, somme per camera (e formati audio).
/// Solo dati registrati: quello che non si conosce è dichiarato (durata parziale, N/D), mai stimato.
struct RecapPanel: View {
    @ObservedObject var projects: ProjectsViewModel
    @AppStorage("showRecap") private var expanded = true

    var body: some View {
        if let recap = projects.recap, let id = projects.selectedNodeID, let node = projects.node(id) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Button {
                        expanded.toggle()
                    } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").frame(width: 12)
                    }
                    .buttonStyle(.plain)
                    Text(tr("Riepilogo di «{0}»", node.name)).appFont(.headline).lineLimit(1)
                    if !recap.isEmpty { Text(summaryLine(recap)).appFont(.callout).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer()
                }
                if let status = projects.importStatus {
                    Text(status).appFont(.caption).foregroundStyle(.secondary)
                }
                if expanded {
                    ScrollView {
                        details(recap).padding(.trailing, 10)
                    }
                    .frame(maxHeight: 290)
                }
            }
            .padding(10)
            Divider()
        }
    }

    private func summaryLine(_ recap: ProjectRecap) -> String {
        var parts = [tr("Schede scaricate: {0}", recap.cardCount), tr("Spazio verificato: {0}", Format.bytes(recap.verifiedBytes))]
        if recap.importedFiles > 0 { parts.append(tr("File importati: {0}", recap.importedFiles)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func details(_ recap: ProjectRecap) -> some View {
        if recap.isEmpty {
            Text(tr("Ancora nessun offload né file importato in questa cartella.")).appFont(.callout).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 18) {
                table(tr("Panoramica clip"), columns: [tr("Clip"), tr("File"), tr("Dimensione")], rows: [
                    [tr("Clip video sorgente")] + overviewCells(recap.video),
                    [tr("Clip audio")] + overviewCells(recap.audio),
                    [tr("Altri file")] + overviewCells(recap.other),
                    [tr("Totale")] + overviewCells(recap.total),
                ])
                table(tr("Backup (verificati)"), columns: [tr("Clip")], rows: recap.backups.map { [$0.label, String($0.clips)] })
                if !recap.videoFormats.isEmpty {
                    table(tr("Formati video"), columns: [tr("Tipo file"), tr("Risoluzione"), tr("FPS"), tr("Clip")],
                          rows: recap.videoFormats.map { [$0.codec ?? na, $0.fileType.isEmpty ? na : $0.fileType, $0.resolution ?? na, $0.fps ?? na, String($0.group.clips)] })
                }
                if !recap.videoCodecs.isEmpty {
                    table(tr("Durata per codec video"), columns: [tr("Clip"), tr("Durata")],
                          rows: recap.videoCodecs.map { [$0.codec ?? na, String($0.group.clips), durationText($0.group)] })
                }
                if !recap.cameras.isEmpty {
                    table(tr("Somme per camera"), columns: [tr("Bobine"), tr("Frame"), tr("Clip"), tr("File"), tr("Dimensione")],
                          rows: recap.cameras.map {
                              [$0.camera ?? na, String($0.reelCount), $0.frames.map(String.init) ?? na, String($0.group.clips),
                               String($0.group.files), Format.bytes($0.group.size)]
                          })
                }
                if !recap.audioFormats.isEmpty {
                    table(tr("Formati audio"), columns: [tr("Frequenza"), tr("Bit"), tr("Canali"), tr("Clip")],
                          rows: recap.audioFormats.map { [$0.codec ?? na, $0.sampleRate ?? na, $0.bitDepth ?? na, $0.channels ?? na, String($0.group.clips)] })
                    table(tr("Durata per codec audio"), columns: [tr("Clip"), tr("Durata")],
                          rows: recap.audioCodecs.map { [$0.codec ?? na, String($0.group.clips), durationText($0.group)] })
                }
                ForEach(notes(recap), id: \.self) { note in
                    Text(note).appFont(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private var na: String { ClipColumns.notAvailable }

    /// Nella panoramica nessuna durata: si somma solo per codec (tabelle «Durata per codec»), mai per progetto.
    private func overviewCells(_ g: ProjectRecap.Group) -> [String] {
        [String(g.clips), String(g.files), Format.bytes(g.size)]
    }

    /// «0» se non ci sono clip; N/D se nessun clip ha la durata; «≥ …» se la conoscono solo alcuni.
    private func durationText(_ g: ProjectRecap.Group) -> String {
        if g.clips == 0 { return Format.duration(0) }
        if g.clipsWithDuration == 0 { return na }
        let text = Format.duration(g.durationSeconds)
        return g.clipsWithoutDuration > 0 ? "≥ \(text)" : text
    }

    /// Tabella: titolo + intestazioni di colonna, poi le righe (la prima colonna è il nome della riga, le altre sono a destra).
    private func table(_ title: String, columns: [String], rows: [[String]]) -> some View {
        Grid(alignment: .trailing, horizontalSpacing: 22, verticalSpacing: 4) {
            GridRow {
                Text(title).appFont(.title3, bold: true).frame(maxWidth: .infinity, alignment: .leading)
                ForEach(Array(columns.enumerated()), id: \.offset) { _, name in
                    Text(name).appFont(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            ForEach(Array(rows.enumerated()), id: \.offset) { _, cells in
                GridRow {
                    ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                        Text(cell)
                            .appFont(.callout, monospacedDigit: true)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: index == 0 ? .infinity : nil, alignment: index == 0 ? .leading : .trailing)
                    }
                }
            }
        }
    }

    private func notes(_ recap: ProjectRecap) -> [String] {
        var out: [String] = []
        if recap.video.clips > 0 && recap.video.clipsWithDuration == 0 {
            out.append(tr("Durata non disponibile: i metadata non sono ancora stati letti (usa «Leggi metadata» nel tab Clip)."))
        } else if recap.video.clipsWithoutDuration > 0 {
            out.append(tr("La durata comprende solo i {0} clip di cui è nota; {1} clip senza durata (usa «Leggi metadata» nel tab Clip).", recap.video.clipsWithDuration, recap.video.clipsWithoutDuration))
        }
        if recap.videoWithoutFormat > 0 {
            out.append(tr("{0} clip senza codec né risoluzione (metadata non letti): compaiono come formato {1}.", recap.videoWithoutFormat, na))
        }
        if recap.audioWithoutFormat > 0 {
            out.append(tr("{0} clip audio senza codec né frequenza (metadata non letti): compaiono come formato {1}.", recap.audioWithoutFormat, na))
        }
        if recap.problemFiles > 0 {
            out.append(tr("{0} file non verificati OK (MISMATCH, errore o offload annullato): compaiono nella riga «0» dei backup.", recap.problemFiles))
        }
        if recap.importedFiles > 0 {
            out.append(tr("{0} file importati senza copia: non sono verificati (riga «0» dei backup).", recap.importedFiles))
        }
        if recap.incompleteOffloads > 0 {
            out.append(tr("{0} offload annullati o interrotti non sono contati come schede scaricate.", recap.incompleteOffloads))
        }
        return out
    }
}

// MARK: - Sorgente

struct SourcePanel: View {
    @ObservedObject var vm: OffloadViewModel
    @State private var isTargeted = false
    @State private var volumesRevision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(tr("Sorgente")).appFont(.headline)
                if let url = vm.sourceURL {
                    Text(url.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Menu(tr("Schede collegate")) {
                    let volumes = OffloadViewModel.connectedVolumes()
                    if volumes.isEmpty { Text(tr("Nessuna scheda o disco esterno collegato")) }
                    ForEach(volumes, id: \.path) { url in
                        Button(url.lastPathComponent) { vm.setSource(url) }
                    }
                }
                .id(volumesRevision)
                .fixedSize()
                .disabled(vm.isRunning)
                Button(tr("Scegli sorgente…")) { vm.chooseSource() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(vm.isRunning)
            }
            if vm.sourceURL != nil {
                HStack(spacing: 8) {
                    Text(tr("Nome bin:"))
                    TextField(tr("Nome del bin"), text: $vm.binName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                        .disabled(vm.isRunning)
                    if let error = vm.binNameError {
                        Text(error).foregroundStyle(.red).appFont(.callout)
                    } else {
                        Text(tr("proposto dalla sorgente: puoi cambiarlo prima di avviare")).foregroundStyle(.secondary).appFont(.callout)
                    }
                }
            }
            if vm.sourceURL == nil {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.5),
                                      style: StrokeStyle(lineWidth: 2, dash: [6]))
                    Text(tr("Trascina qui la scheda (o la cartella sorgente)"))
                        .foregroundStyle(.secondary)
                }
                .frame(maxHeight: .infinity)
            } else {
                HStack(spacing: 16) {
                    if vm.runState == .scanning {
                        ProgressView().controlSize(.small)
                        Text(tr("Lettura elenco file…"))
                    } else {
                        Text(tr("{0} file", vm.rows.count))
                        Text(tr("Dimensione totale: {0}", Format.bytes(vm.totalSize)))
                        if !vm.skippedItems.isEmpty {
                            Text(tr("{0} elementi non copiabili", vm.skippedItems.count))
                                .foregroundStyle(.orange)
                                .help(vm.skippedItems.map { "\($0.relativePath): \($0.reason)" }.joined(separator: "\n"))
                        }
                    }
                }
                .appFont(.callout)
                Table(vm.rows) {
                    TableColumn(tr("Nome")) { row in Text(row.file.name) }
                    TableColumn(tr("Cartella")) { row in Text(row.file.folder).foregroundStyle(.secondary) }
                    TableColumn(tr("Dimensione")) { row in Text(Format.bytes(row.file.size)) }
                        .width(min: 90, ideal: 100)
                    TableColumn(tr("Stato")) { row in StatusBadge(status: vm.aggregateStatus(row.index)) }
                        .width(min: 90, ideal: 110)
                }
            }
        }
        .padding(12)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in volumesRevision += 1 }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in volumesRevision += 1 }
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { vm.setSource(url) } }
            }
            return true
        }
    }
}

struct StatusBadge: View {
    let status: DestFileStatus?

    var body: some View {
        if let status {
            Text(status.label)
                .appFont(.caption, bold: true)
                .foregroundStyle(color(status))
        } else {
            Text("")
        }
    }

    private func color(_ s: DestFileStatus) -> Color {
        switch s {
        case .ok: return .green
        case .mismatch, .error: return .red
        case .pending: return .secondary
        default: return .blue
        }
    }
}

// MARK: - Destinazioni

struct DestinationsPanel: View {
    @ObservedObject var vm: OffloadViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(tr("Destinazioni (verrà creata la cartella del bin dentro quella scelta)")).appFont(.headline)
                Spacer()
                Menu(tr("Percorsi salvati")) {
                    Button(tr("Salva i percorsi scelti")) { vm.saveChosenDestinations() }
                        .disabled(!vm.canSaveChosenDestinations)
                    if !vm.savedPaths.isEmpty {
                        Divider()
                        ForEach(vm.savedPaths, id: \.self) { path in
                            Button(vm.isSavedPathAvailable(path) ? path : tr("{0} (non disponibile)", path)) { vm.useSavedPath(path) }
                                .disabled(!vm.isSavedPathAvailable(path))
                        }
                        Divider()
                        Button(tr("Usa tutti i percorsi salvati")) { vm.useAllSavedPaths() }
                        Menu(tr("Rimuovi dai salvati")) {
                            ForEach(vm.savedPaths, id: \.self) { path in
                                Button(path) { vm.removeSavedPath(path) }
                            }
                        }
                    }
                }
                .fixedSize()
                .disabled(vm.isRunning)
                .help(tr("Salva i percorsi di destinazione che usi di solito, per non sceglierli ogni volta"))
                Button(tr("Aggiungi destinazione")) { vm.addDestination() }
                    .disabled(vm.destinations.count >= OffloadJob.maxDestinations || vm.isRunning)
            }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(Array(vm.destinations.enumerated()), id: \.element.id) { index, slot in
                        DestinationRow(vm: vm, slot: slot, index: index)
                    }
                }
            }
        }
        .padding(12)
    }
}

struct DestinationRow: View {
    @ObservedObject var vm: OffloadViewModel
    let slot: DestinationSlot
    let index: Int

    private var progress: DestinationProgress? {
        index < vm.snapshot.destinations.count ? vm.snapshot.destinations[index] : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(tr("Destinazione {0}", index + 1)).bold()
                Text(slot.url?.path ?? tr("nessuna cartella selezionata"))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(tr("Scegli…")) { vm.chooseDestination(slot) }.disabled(vm.isRunning)
                if !vm.savedPaths.isEmpty {
                    Menu {
                        ForEach(vm.savedPaths, id: \.self) { path in
                            Button(path) { vm.assignSavedPath(path, to: slot) }
                                .disabled(!vm.isSavedPathAvailable(path))
                        }
                    } label: {
                        Image(systemName: "star")
                    }
                    .fixedSize()
                    .disabled(vm.isRunning)
                    .help(tr("Usa un percorso salvato per questa destinazione"))
                }
                if vm.destinations.count > 1 {
                    Button(tr("Rimuovi")) { vm.removeDestination(slot) }.disabled(vm.isRunning)
                }
            }
            if let p = progress, p.totalBytes > 0 {
                let copy = Double(p.writtenBytes) / Double(p.totalBytes)
                let verify = Double(p.verifiedBytes) / Double(p.totalBytes)
                ProgressView(value: min(1, (copy + verify) / 2))
                HStack(spacing: 14) {
                    Text(tr("Copia {0}%  {1}", Int(min(1, copy) * 100), Format.megabytesPerSecond(p.writeSpeed)))
                    Text(tr("Verifica {0}%  {1}", Int(min(1, verify) * 100), Format.megabytesPerSecond(p.verifySpeed)))
                    Text(tr("Tempo {0}", Format.duration(vm.snapshot.elapsed)))
                    Text(tr("ETA {0}", Format.duration(p.eta)))
                    Spacer()
                    Text(tr("OK {0}", p.okCount)).foregroundStyle(.green)
                    Text(tr("MISMATCH {0}", p.mismatchCount)).foregroundStyle(p.mismatchCount > 0 ? Color.red : Color.secondary)
                    Text(tr("ERRORE {0}", p.errorCount)).foregroundStyle(p.errorCount > 0 ? Color.red : Color.secondary)
                }
                .appFont(.caption, monospacedDigit: true)
                if let fatal = p.fatalError {
                    Text(tr("Destinazione interrotta: {0}", fatal)).appFont(.caption).foregroundStyle(.red)
                }
            } else {
                ProgressView(value: 0)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
}

// MARK: - Barra di controllo

struct ControlBar: View {
    @ObservedObject var vm: OffloadViewModel
    @AppStorage("overlapVerification") private var overlapVerification = true
    @AppStorage("clearSourceWhenDone") private var clearSourceWhenDone = true
    @AppStorage("ascMHL") private var ascMHL = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 18) {
                Text(vm.snapshot.phase.label).bold()
                Text(tr("Lettura sorgente: {0}", Format.megabytesPerSecond(vm.snapshot.readSpeed)))
                Text(tr("Tempo: {0}", Format.duration(vm.snapshot.elapsed)))
                Text(tr("ETA: {0}", Format.duration(vm.snapshot.eta)))
                if let file = vm.snapshot.currentFile, vm.isRunning {
                    Text(file).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button(tr("Riprendi")) { vm.resume() }
                    .disabled(vm.resumable == nil || vm.runState != .idle)
                Button(tr("Annulla")) { vm.cancel() }
                    .disabled(!vm.isRunning)
                Button(tr("Avvia")) { vm.start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!vm.canStart)
            }
            .appFont(.callout, monospacedDigit: true)
            HStack(spacing: 18) {
                Toggle(tr("Verifica durante la copia"), isOn: $overlapVerification)
                    .toggleStyle(.checkbox)
                    .disabled(vm.isRunning)
                    .help(tr("Ogni file viene riletto e confrontato appena scritto, mentre la copia prosegue: più veloce con dischi SSD. Disattivala con dischi lenti (HDD): la verifica partirà a copia finita."))
                Toggle(tr("Crea certificato ASC MHL"), isOn: $ascMHL)
                    .toggleStyle(.checkbox)
                    .disabled(vm.isRunning)
                    .help(tr("A offload riuscito scrive nella cartella della copia la cartella «ascmhl» con il certificato degli hash (formato ASC MHL 2.0, come Silverstack). Non viene creato se qualche file non è verificato OK."))
                Toggle(tr("Svuota la sorgente a fine offload"), isOn: $clearSourceWhenDone)
                    .toggleStyle(.checkbox)
                    .help(tr("Quando tutti i file sono OK la parte «Sorgente» si svuota da sola, pronta per la scheda successiva. Se ci sono problemi resta l'elenco dei file."))
                if let result = vm.result, result.outcome == .completed, result.allOK, vm.runState == .idle, vm.ejectableSourceVolume != nil {
                    Button(tr("Espelli sorgente")) { vm.ejectSource() }
                        .help(tr("Smonta ed espelle la scheda: solo dopo un offload con tutti i file OK"))
                }
                Spacer()
            }
            .appFont(.callout)
            if let result = vm.result { ResultBanner(result: result) }
        }
        .padding(12)
    }
}

struct ResultBanner: View {
    let result: OffloadResult

    var body: some View {
        let mismatches = result.files.reduce(0) { $0 + $1.destinations.filter { $0.status == .mismatch }.count }
        let errors = result.files.reduce(0) { $0 + $1.destinations.filter { $0.status == .error }.count }
        VStack(alignment: .leading, spacing: 4) {
            switch result.outcome {
            case .preflightFailed:
                banner(tr("NON AVVIATO: controlli preliminari falliti"), .red)
            case .cancelled:
                banner(tr("ANNULLATO: i file parziali sono stati rimossi. «Riprendi» continua dai file già verificati."), .orange)
            case .completed:
                if result.allOK {
                    banner(tr("TUTTI I FILE OK: {0} file riletti dal disco con XXH64 identico alla sorgente su {1} destinazione/i.", result.files.count, result.job.destinationRoots.count), .green)
                } else {
                    banner(tr("ATTENZIONE: {0} MISMATCH, {1} ERRORI, {2} destinazioni interrotte. I file non OK non vanno considerati copiati.", mismatches, errors, result.destinationErrors.compactMap { $0 }.count), .red)
                }
            }
            mhlLine
        }
    }

    /// Esito del certificato ASC MHL (solo se la funzione era attiva).
    @ViewBuilder private var mhlLine: some View {
        let written = result.mhl.filter { if case .written = $0 { return true } else { return false } }.count
        let problems: [String] = result.mhl.compactMap {
            switch $0 {
            case .skipped(let reason)?: return reason
            case .failed(let reason)?: return reason
            default: return nil
            }
        }
        if written > 0 {
            Text(tr("Certificato ASC MHL scritto su {0} destinazione/i (cartella «ascmhl»).", written))
                .appFont(.callout).foregroundStyle(.secondary)
        }
        if !problems.isEmpty {
            Text(tr("Certificato ASC MHL NON creato su {0} destinazione/i: {1}", problems.count, Array(Set(problems)).sorted().joined(separator: "; ")))
                .appFont(.callout).foregroundStyle(.orange)
        }
    }

    private func banner(_ text: String, _ color: Color) -> some View {
        Text(text)
            .appFont(.callout, bold: true)
            .foregroundStyle(.white)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(color))
    }
}
#endif
