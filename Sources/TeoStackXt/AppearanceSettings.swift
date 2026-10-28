#if canImport(SwiftUI)
import SwiftUI
import AppKit
import TeoStackCore

/// Aspetto scelto dall'utente (sfondo, scritte, carattere, dimensione). Si ricorda tra un avvio e l'altro.
final class AppearanceSettings: ObservableObject {
    static let shared = AppearanceSettings()

    @Published var preferences: AppearancePreferences {
        didSet { preferences.save() }
    }

    private init() {
        preferences = AppearancePreferences.load()
    }

    // MARK: Colori

    static func color(_ hex: String?) -> Color? {
        guard let hex, let c = AppearancePreferences.rgb(hex) else { return nil }
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1)
    }

    static func hex(of color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.black
        return AppearancePreferences.hex(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent))
    }

    var background: Color? { Self.color(preferences.backgroundHex) }
    var text: Color? { Self.color(preferences.textHex) }

    /// Chiaro/scuro forzato in base allo sfondo scelto (così i controlli del sistema restano leggibili); nil = segue il sistema.
    var colorScheme: ColorScheme? {
        guard let dark = preferences.backgroundIsDark else { return nil }
        return dark ? .dark : .light
    }

    // MARK: Caratteri

    /// Caratteri proposti (solo quelli installati sul Mac).
    static var availableFonts: [String] {
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        return ["Helvetica Neue", "Avenir Next", "Avenir", "Optima", "Futura", "Gill Sans", "Verdana", "Trebuchet MS", "Georgia", "Palatino",
                "Baskerville", "Menlo", "Monaco", "Courier New", "American Typewriter"].filter { installed.contains($0) }
    }

    /// Il carattere per uno stile di testo. Senza scelte dell'utente è identico a quello di sempre.
    func font(_ style: AppearancePreferences.TextStyle, bold: Bool = false, monospacedDigit: Bool = false, monospaced: Bool = false) -> Font {
        let size = CGFloat(preferences.size(style))
        var font: Font
        if let name = preferences.fontName, !monospaced {
            font = Font.custom(name, size: size)
        } else if preferences.sizeScale != 1 || monospaced {
            font = Font.system(size: size, weight: style == .headline ? .semibold : .regular, design: monospaced ? .monospaced : .default)
        } else {
            font = Self.systemFont(style)
        }
        if bold { font = font.bold() }
        if monospacedDigit { font = font.monospacedDigit() }
        return font
    }

    private static func systemFont(_ style: AppearancePreferences.TextStyle) -> Font {
        switch style {
        case .largeTitle: return .largeTitle
        case .title: return .title
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .body: return .body
        case .callout: return .callout
        case .subheadline: return .subheadline
        case .footnote: return .footnote
        case .caption: return .caption
        case .caption2: return .caption2
        }
    }
}

/// Come `.font(.callout)` ma segue il carattere e la dimensione scelti nelle impostazioni.
private struct AppFontModifier: ViewModifier {
    @ObservedObject private var settings = AppearanceSettings.shared
    let style: AppearancePreferences.TextStyle
    let bold: Bool
    let monospacedDigit: Bool
    let monospaced: Bool

    func body(content: Content) -> some View {
        content.font(settings.font(style, bold: bold, monospacedDigit: monospacedDigit, monospaced: monospaced))
    }
}

extension View {
    func appFont(_ style: AppearancePreferences.TextStyle, bold: Bool = false, monospacedDigit: Bool = false, monospaced: Bool = false) -> some View {
        modifier(AppFontModifier(style: style, bold: bold, monospacedDigit: monospacedDigit, monospaced: monospaced))
    }
}

/// Applica sfondo, colore delle scritte e carattere a tutta la finestra.
struct AppearanceModifier: ViewModifier {
    @ObservedObject private var settings = AppearanceSettings.shared

    func body(content: Content) -> some View {
        content
            .appFont(.body)
            .foregroundStyle(settings.text.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.foreground))
            .scrollContentBackground(settings.background == nil ? .automatic : .hidden)
            .background((settings.background ?? Color.clear).ignoresSafeArea())
            .preferredColorScheme(settings.colorScheme)
    }
}

extension View {
    func appAppearance() -> some View { modifier(AppearanceModifier()) }
}

extension Notification.Name {
    static let openSettings = Notification.Name("TeoStackXtOpenSettings")
}

// MARK: - Finestra «Impostazioni»

struct SettingsSheet: View {
    @ObservedObject private var settings = AppearanceSettings.shared
    let onClose: () -> Void

    private var backgroundBinding: Binding<Color> {
        Binding(get: { settings.background ?? Color(nsColor: .windowBackgroundColor) },
                set: { settings.preferences.backgroundHex = AppearanceSettings.hex(of: $0) })
    }

    private var textBinding: Binding<Color> {
        Binding(get: { settings.text ?? Color.primary },
                set: { settings.preferences.textHex = AppearanceSettings.hex(of: $0) })
    }

    private var fontBinding: Binding<String> {
        Binding(get: { settings.preferences.fontName ?? "" },
                set: { settings.preferences.fontName = $0.isEmpty ? nil : $0 })
    }

    private var scaleBinding: Binding<Double> {
        Binding(get: { settings.preferences.sizeScale },
                set: { settings.preferences.sizeScale = AppearancePreferences.clamp($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("Impostazioni")).appFont(.title3, bold: true)

            Text(tr("Aspetto")).appFont(.headline)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(tr("Modelli pronti")).frame(width: 130, alignment: .leading)
                    Menu(tr("Scegli…")) {
                        ForEach(AppearancePreferences.presets, id: \.name) { preset in
                            Button(tr(preset.name)) { settings.preferences = preset.preferences }
                        }
                    }
                    .fixedSize()
                }
                HStack {
                    Text(tr("Colore dello sfondo")).frame(width: 130, alignment: .leading)
                    ColorPicker("", selection: backgroundBinding, supportsOpacity: false).labelsHidden()
                    Button(tr("Predefinito")) { settings.preferences.backgroundHex = nil }
                        .disabled(settings.preferences.backgroundHex == nil)
                }
                HStack {
                    Text(tr("Colore delle scritte")).frame(width: 130, alignment: .leading)
                    ColorPicker("", selection: textBinding, supportsOpacity: false).labelsHidden()
                    Button(tr("Predefinito")) { settings.preferences.textHex = nil }
                        .disabled(settings.preferences.textHex == nil)
                }
                HStack {
                    Text(tr("Carattere")).frame(width: 130, alignment: .leading)
                    Picker("", selection: fontBinding) {
                        Text(tr("Di sistema")).tag("")
                        ForEach(AppearanceSettings.availableFonts, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
                HStack {
                    Text(tr("Dimensione delle scritte")).frame(width: 130, alignment: .leading)
                    Slider(value: scaleBinding, in: AppearancePreferences.sizeRange, step: 0.05).frame(width: 220)
                    Text("\(Int((settings.preferences.sizeScale * 100).rounded()))%").monospacedDigit().frame(width: 48, alignment: .trailing)
                }
            }

            if settings.preferences.lowContrast {
                Text(tr("Attenzione: sfondo e scritte hanno colori troppo simili, si legge male."))
                    .appFont(.callout)
                    .foregroundStyle(Color.orange)
            }

            Text(tr("Anteprima")).appFont(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text("A001C002_240101_R1AB.mov").appFont(.headline)
                Text(tr("Offload completato: tutti i file OK")).appFont(.body)
                Text("ARRI ALEXA 35 · 4608x3164 · 24 fps · 01:00:00:00").appFont(.callout)
                Text(tr("Esempio di testo piccolo")).appFont(.caption)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(settings.text ?? Color.primary)
            .background(RoundedRectangle(cornerRadius: 8).fill(settings.background ?? Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.4)))

            HStack {
                Button(tr("Ripristina predefiniti")) { settings.preferences = .standard }
                    .disabled(settings.preferences.isStandard)
                Spacer()
                Button(tr("Chiudi")) { onClose() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .appAppearance()
    }
}
#endif
