#if canImport(SwiftUI)
import SwiftUI
import AppKit

@main
struct TeoStackXtApp: App {
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
    }
}
#endif
