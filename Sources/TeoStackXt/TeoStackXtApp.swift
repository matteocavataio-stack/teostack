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
        WindowGroup("TeoStackXt") {
            ContentView()
        }
        .windowResizability(.contentMinSize)
        .commands {
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
