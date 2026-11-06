#if canImport(SwiftUI)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TeoStackCore

/// Finestra «Opzioni progetto»: opzioni dell'offload e loghi PROGETTO / SERVICE dei report, salvati per il progetto selezionato.
struct ProjectSettingsSheet: View {
    @ObservedObject var projects: ProjectsViewModel
    let onSaved: () -> Void
    let onClose: () -> Void

    @State private var settings = ProjectSettings()
    @State private var message: String?

    private var projectName: String { projects.selectedProject?.name ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("Impostazioni del progetto «{0}»", projectName)).appFont(.title3, bold: true)

            Text(tr("Offload")).appFont(.headline)
            VStack(alignment: .leading, spacing: 8) {
                Toggle(tr("Verifica durante la copia"), isOn: $settings.overlapVerification)
                    .toggleStyle(.checkbox)
                    .help(tr("Ogni file viene riletto e confrontato appena scritto, mentre la copia prosegue: più veloce con dischi SSD. Disattivala con dischi lenti (HDD): la verifica partirà a copia finita."))
                Toggle(tr("Crea certificato ASC MHL"), isOn: $settings.ascMHL)
                    .toggleStyle(.checkbox)
                    .help(tr("A offload riuscito scrive nella cartella della copia la cartella «ascmhl» con il certificato degli hash (formato ASC MHL 2.0, come Silverstack). Non viene creato se qualche file non è verificato OK."))
                Toggle(tr("Svuota la sorgente a fine offload"), isOn: $settings.clearSourceWhenDone)
                    .toggleStyle(.checkbox)
                    .help(tr("Quando tutti i file sono OK la parte «Sorgente» si svuota da sola, pronta per la scheda successiva. Se ci sono problemi resta l'elenco dei file."))
            }
            .appFont(.callout)

            Divider()

            Text(tr("Loghi dei report")).appFont(.headline)
            Text(tr("Compaiono in testa a ogni pagina di tutti i report di questo progetto: PROGETTO a sinistra, SERVICE a destra. Puoi scegliere PNG, JPEG, TIFF o PDF: l'immagine viene convertita in JPEG su fondo bianco."))
                .appFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LogoRow(title: tr("PROGETTO (a sinistra)"), data: $settings.projectLogo, message: $message)
            LogoRow(title: tr("SERVICE (a destra)"), data: $settings.serviceLogo, message: $message)

            if let message {
                Text(message).appFont(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(tr("Annulla"), action: onClose)
                Button(tr("Salva")) { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 560)
        .onAppear { load() }
    }

    private func load() {
        settings = projects.projectSettings()
    }

    private func save() {
        guard let store = projects.store, let id = projects.selectedProjectID else { return }
        do {
            try store.saveSettings(settings, projectID: id)
            onSaved()
            onClose()
        } catch {
            message = "\(error)"
        }
    }
}

/// Una riga «titolo · anteprima del logo · Scegli immagine… · Rimuovi».
private struct LogoRow: View {
    let title: String
    @Binding var data: Data?
    @Binding var message: String?

    var body: some View {
        HStack(spacing: 10) {
            Text(title).appFont(.callout, bold: true).frame(width: 150, alignment: .leading)
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color.white)
                RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.5))
                if let data, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFit().padding(3)
                } else {
                    Text(tr("Nessun logo")).appFont(.caption).foregroundStyle(.gray)
                }
            }
            .frame(width: 150, height: 50)
            Button(tr("Scegli immagine…")) { choose() }
            Button(tr("Rimuovi")) { data = nil }.disabled(data == nil)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image, .pdf]
        panel.message = tr("Scegli l'immagine del logo")
        panel.prompt = tr("Scegli")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let jpeg = LogoImage.jpegData(from: url), (try? ProjectSettings.validateLogo(jpeg)) != nil {
            data = jpeg
            message = nil
        } else {
            message = tr("Immagine non utilizzabile: scegli un file PNG, JPEG, TIFF o PDF.")
        }
    }
}
#endif
