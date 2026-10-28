#if canImport(SwiftUI)
import SwiftUI
import TeoStackCore

/// Lingua dell'interfaccia (Italiano, English, Castellano, Català). La scelta si ricorda tra un avvio e l'altro.
final class LanguageSettings: ObservableObject {
    static let shared = LanguageSettings()

    @Published var language: AppLanguage {
        didSet {
            Loc.language = language
            Loc.save(language)
        }
    }

    private init() {
        let saved = Loc.savedLanguage()
        language = saved
        Loc.language = saved
    }
}

/// Pulsante in basso a sinistra per cambiare lingua.
struct LanguageMenu: View {
    @ObservedObject private var settings = LanguageSettings.shared

    var body: some View {
        Menu {
            ForEach(AppLanguage.allCases) { language in
                Button {
                    settings.language = language
                } label: {
                    if language == settings.language {
                        Label(language.displayName, systemImage: "checkmark")
                    } else {
                        Text(language.displayName)
                    }
                }
            }
        } label: {
            Label(settings.language.displayName, systemImage: "globe")
        }
        .fixedSize()
        .help(tr("Lingua dell'interfaccia"))
    }
}
#endif
