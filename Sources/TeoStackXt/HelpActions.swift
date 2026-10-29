#if canImport(SwiftUI)
import SwiftUI
import AppKit
import TeoStackCore

/// Aiuto: il manuale utente in PDF (creato dall'app, nella lingua scelta).
enum HelpActions {
    /// Crea il manuale in una cartella temporanea e lo apre con il programma predefinito per i PDF (Anteprima).
    static func openManual() {
        do {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TeoStackPro-Aiuto", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(ManualPDF.fileName(for: Loc.language))
            try ManualPDF.render().write(to: url, options: .atomic)
            NSWorkspace.shared.open(url)
        } catch {
            show(error)
        }
    }

    /// Salva il manuale dove sceglie l'utente.
    static func saveManual() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ManualPDF.fileName(for: Loc.language)
        panel.message = tr("Salva il manuale utente (PDF).")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ManualPDF.render().write(to: url, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            show(error)
        }
    }

    private static func show(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = tr("Impossibile creare il manuale: {0}", "\(error)")
        alert.runModal()
    }
}

/// Menu «Aiuto» in basso a sinistra, accanto a lingua e impostazioni.
struct HelpMenu: View {
    var body: some View {
        Menu {
            Button(tr("Apri il manuale (PDF)")) { HelpActions.openManual() }
            Button(tr("Salva il manuale come…")) { HelpActions.saveManual() }
        } label: {
            Label(tr("Aiuto"), systemImage: "questionmark.circle")
        }
        .fixedSize()
        .help(tr("Apre il manuale utente in PDF, nella lingua scelta."))
    }
}
#endif
