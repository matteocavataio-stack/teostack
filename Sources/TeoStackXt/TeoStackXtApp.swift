#if canImport(SwiftUI)
import SwiftUI
import AppKit
import TeoStackCore

@main
struct TeoStackXtApp: App {
    /// Fa ridisegnare anche il menu in alto quando cambia la lingua.
    @StateObject private var language = LanguageSettings.shared

    init() {
        // Necessario per avere finestra e menu anche quando l'app viene lanciata con `swift run`.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("TeoStackPro") {
            ContentView()
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(tr("Impostazioni…")) {
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button(tr("Manuale di TeoStackPro")) { HelpActions.openManual() }
                    .keyboardShortcut("?", modifiers: .command)
                Button(tr("Salva il manuale come…")) { HelpActions.saveManual() }
            }
            CommandMenu(tr("Report")) {
                Button(tr("Esporta report…")) {
                    NotificationCenter.default.post(name: .exportReport, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }
    }
}
#endif
