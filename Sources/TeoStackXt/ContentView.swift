#if canImport(SwiftUI)
import SwiftUI
import UniformTypeIdentifiers
import TeoStackCore

enum MainTab: String, CaseIterable, Identifiable {
    case offload = "Offload"
    case clips = "Clip"
    var id: String { rawValue }
}

struct ContentView: View {
    @StateObject private var app = AppModel()
    @State private var request: NameRequest?
    @State private var tab: MainTab = .offload
    @AppStorage("showHistory") private var showHistory = true

    var body: some View {
        VStack(spacing: 0) {
            ProjectBar(projects: app.projects, request: $request)
            Divider()
            DependencyBanner(tools: app.tools)
            HSplitView {
                SidebarView(projects: app.projects, request: $request)
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 420)
                VStack(spacing: 0) {
                    HStack {
                        Picker("", selection: $tab) {
                            ForEach(MainTab.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 260)
                        Spacer()
                        Button(showHistory ? "Nascondi cronologia" : "Mostra cronologia") { showHistory.toggle() }
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
        .frame(minWidth: 1280, minHeight: 760)
        .onReceive(app.projects.$binTarget) { app.offload.target = $0 }
        .sheet(item: $request) { req in
            NameSheet(request: req, onSubmit: { submit(req, $0) }, onClose: { request = nil })
        }
        .alert("Errore", isPresented: Binding(get: { app.projects.errorMessage != nil || app.offload.errorMessage != nil },
                                              set: { if !$0 { app.projects.errorMessage = nil; app.offload.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text([app.projects.errorMessage, app.offload.errorMessage].compactMap { $0 }.joined(separator: "\n"))
        }
    }

    private func submit(_ req: NameRequest, _ name: String) -> String? {
        switch req {
        case .newProject: return app.projects.createProject(name: name)
        case .renameProject: return app.projects.renameProject(name: name)
        case .newDay: return app.projects.createDay(name: name)
        case .newBin: return app.projects.createBin(name: name)
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

/// Mostra in quale bin del progetto verrà registrato l'offload e dove finiranno i file sui dischi.
struct TargetBar: View {
    @ObservedObject var vm: OffloadViewModel
    @ObservedObject var projects: ProjectsViewModel

    var body: some View {
        HStack(spacing: 8) {
            Text("Destinazione nel progetto:").font(.headline)
            if let t = vm.target {
                Text("\(t.projectName) › \(t.dayName) › \(t.binName)").bold()
                let n = projects.offloadCount(binID: t.binID)
                if n > 0 {
                    Text("(il bin contiene già \(n) offload)").foregroundStyle(.orange).font(.callout)
                }
            } else {
                Text("seleziona un bin nella barra laterale (o creane uno con «+ Giorno» e «+ Bin»)")
                    .foregroundStyle(.red)
            }
            Spacer()
        }
        .padding(10)
    }
}

// MARK: - Sorgente

struct SourcePanel: View {
    @ObservedObject var vm: OffloadViewModel
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sorgente").font(.headline)
                if let url = vm.sourceURL {
                    Text(url.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("Scegli sorgente…") { vm.chooseSource() }
                    .disabled(vm.isRunning)
            }
            if vm.sourceURL == nil {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.5),
                                      style: StrokeStyle(lineWidth: 2, dash: [6]))
                    Text("Trascina qui la scheda (o la cartella sorgente)")
                        .foregroundStyle(.secondary)
                }
                .frame(maxHeight: .infinity)
            } else {
                HStack(spacing: 16) {
                    if vm.runState == .scanning {
                        ProgressView().controlSize(.small)
                        Text("Lettura elenco file…")
                    } else {
                        Text("\(vm.rows.count) file")
                        Text("Dimensione totale: \(Format.bytes(vm.totalSize))")
                        if !vm.skippedItems.isEmpty {
                            Text("\(vm.skippedItems.count) elementi non copiabili")
                                .foregroundStyle(.orange)
                                .help(vm.skippedItems.map { "\($0.relativePath): \($0.reason)" }.joined(separator: "\n"))
                        }
                    }
                }
                .font(.callout)
                Table(vm.rows) {
                    TableColumn("Nome") { row in Text(row.file.name) }
                    TableColumn("Cartella") { row in Text(row.file.folder).foregroundStyle(.secondary) }
                    TableColumn("Dimensione") { row in Text(Format.bytes(row.file.size)) }
                        .width(min: 90, ideal: 100)
                    TableColumn("Stato") { row in StatusBadge(status: vm.aggregateStatus(row.index)) }
                        .width(min: 90, ideal: 110)
                }
            }
        }
        .padding(12)
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
                .font(.caption.bold())
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
                Text("Destinazioni (verrà creata la cartella del bin dentro quella scelta)").font(.headline)
                Spacer()
                Button("Aggiungi destinazione") { vm.addDestination() }
                    .disabled(vm.destinations.count >= 3 || vm.isRunning)
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
                Text("Destinazione \(index + 1)").bold()
                Text(slot.url?.path ?? "nessuna cartella selezionata")
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Scegli…") { vm.chooseDestination(slot) }.disabled(vm.isRunning)
                if vm.destinations.count > 1 {
                    Button("Rimuovi") { vm.removeDestination(slot) }.disabled(vm.isRunning)
                }
            }
            if let p = progress, p.totalBytes > 0 {
                let copy = Double(p.writtenBytes) / Double(p.totalBytes)
                let verify = Double(p.verifiedBytes) / Double(p.totalBytes)
                ProgressView(value: min(1, (copy + verify) / 2))
                HStack(spacing: 14) {
                    Text("Copia \(Int(min(1, copy) * 100))%  \(Format.megabytesPerSecond(p.writeSpeed))")
                    Text("Verifica \(Int(min(1, verify) * 100))%  \(Format.megabytesPerSecond(p.verifySpeed))")
                    Text("Tempo \(Format.duration(vm.snapshot.elapsed))")
                    Text("ETA \(Format.duration(p.eta))")
                    Spacer()
                    Text("OK \(p.okCount)").foregroundStyle(.green)
                    Text("MISMATCH \(p.mismatchCount)").foregroundStyle(p.mismatchCount > 0 ? Color.red : Color.secondary)
                    Text("ERRORE \(p.errorCount)").foregroundStyle(p.errorCount > 0 ? Color.red : Color.secondary)
                }
                .font(.caption.monospacedDigit())
                if let fatal = p.fatalError {
                    Text("Destinazione interrotta: \(fatal)").font(.caption).foregroundStyle(.red)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 18) {
                Text(vm.snapshot.phase.label).bold()
                Text("Lettura sorgente: \(Format.megabytesPerSecond(vm.snapshot.readSpeed))")
                Text("Tempo: \(Format.duration(vm.snapshot.elapsed))")
                Text("ETA: \(Format.duration(vm.snapshot.eta))")
                if let file = vm.snapshot.currentFile, vm.isRunning {
                    Text(file).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("Riprendi") { vm.resume() }
                    .disabled(vm.resumable == nil || vm.runState != .idle)
                Button("Annulla") { vm.cancel() }
                    .disabled(!vm.isRunning)
                Button("Avvia") { vm.start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!vm.canStart)
            }
            .font(.callout.monospacedDigit())
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
        Group {
            switch result.outcome {
            case .preflightFailed:
                banner("NON AVVIATO: controlli preliminari falliti", .red)
            case .cancelled:
                banner("ANNULLATO: i file parziali sono stati rimossi. «Riprendi» continua dai file già verificati.", .orange)
            case .completed:
                if result.allOK {
                    banner("TUTTI I FILE OK: \(result.files.count) file riletti dal disco con XXH64 identico alla sorgente su \(result.job.destinationRoots.count) destinazione/i.", .green)
                } else {
                    banner("ATTENZIONE: \(mismatches) MISMATCH, \(errors) ERRORI, \(result.destinationErrors.compactMap { $0 }.count) destinazioni interrotte. I file non OK non vanno considerati copiati.", .red)
                }
            }
        }
    }

    private func banner(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.callout.bold())
            .foregroundStyle(.white)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(color))
    }
}
#endif
