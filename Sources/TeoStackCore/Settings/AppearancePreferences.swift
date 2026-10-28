import Foundation

/// Aspetto personalizzabile dell'app: colore dello sfondo e delle scritte, tipo di carattere e dimensione.
/// Un valore nil = quello del sistema (chiaro/scuro automatico, carattere di sistema, dimensione normale).
public struct AppearancePreferences: Codable, Equatable {
    /// Colore in esadecimale «RRGGBB» (sRGB), senza «#».
    public var backgroundHex: String?
    public var textHex: String?
    /// Nome del carattere (famiglia); nil = carattere di sistema.
    public var fontName: String?
    /// Moltiplicatore delle dimensioni delle scritte (1 = normale).
    public var sizeScale: Double

    public static let sizeRange: ClosedRange<Double> = 0.8 ... 1.5
    public static let standard = AppearancePreferences(backgroundHex: nil, textHex: nil, fontName: nil, sizeScale: 1)

    public init(backgroundHex: String? = nil, textHex: String? = nil, fontName: String? = nil, sizeScale: Double = 1) {
        self.backgroundHex = Self.normalized(backgroundHex)
        self.textHex = Self.normalized(textHex)
        let name = fontName?.trimmingCharacters(in: .whitespaces)
        self.fontName = (name?.isEmpty ?? true) ? nil : name
        self.sizeScale = Self.clamp(sizeScale)
    }

    public var isStandard: Bool { self == .standard }

    // MARK: Colori

    /// «#1a2B3c», «1A2B3C» → «1A2B3C»; nil se non è un colore a 6 cifre esadecimali.
    public static func normalized(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, s.allSatisfy({ $0.isHexDigit }) else { return nil }
        return s.uppercased()
    }

    public static func rgb(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        guard let h = normalized(hex), let v = UInt32(h, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    public static func hex(r: Double, g: Double, b: Double) -> String {
        func c(_ x: Double) -> Int { Int((min(1, max(0, x)) * 255).rounded()) }
        return String(format: "%02X%02X%02X", c(r), c(g), c(b))
    }

    /// Luminanza relativa (WCAG) 0…1.
    public static func luminance(_ hex: String) -> Double? {
        guard let (r, g, b) = rgb(hex) else { return nil }
        func lin(_ x: Double) -> Double { x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// Rapporto di contrasto WCAG tra due colori (1…21).
    public static func contrast(_ a: String, _ b: String) -> Double? {
        guard let la = luminance(a), let lb = luminance(b) else { return nil }
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Lo sfondo scelto è scuro? (serve a far adattare i controlli del sistema). nil se lo sfondo è quello di sistema.
    public var backgroundIsDark: Bool? {
        guard let bg = backgroundHex, let l = Self.luminance(bg) else { return nil }
        return l < 0.4
    }

    /// Avviso se sfondo e scritte sono troppo simili per leggere (contrasto sotto 3).
    public var lowContrast: Bool {
        guard let bg = backgroundHex, let fg = textHex, let c = Self.contrast(bg, fg) else { return false }
        return c < 3
    }

    // MARK: Dimensione

    public static func clamp(_ scale: Double) -> Double {
        guard scale.isFinite else { return 1 }
        return min(sizeRange.upperBound, max(sizeRange.lowerBound, (scale * 20).rounded() / 20))
    }

    /// Dimensione in punti di uno stile di testo di macOS (caption = 10, callout = 12, body/headline = 13…), moltiplicata per `sizeScale`.
    public static func baseSize(_ style: TextStyle) -> Double {
        switch style {
        case .largeTitle: return 26
        case .title: return 22
        case .title2: return 17
        case .title3: return 15
        case .headline, .body: return 13
        case .callout: return 12
        case .subheadline: return 11
        case .footnote, .caption, .caption2: return 10
        }
    }

    public enum TextStyle: String, CaseIterable { case largeTitle, title, title2, title3, headline, body, callout, subheadline, footnote, caption, caption2 }

    public func size(_ style: TextStyle) -> Double { (Self.baseSize(style) * sizeScale * 10).rounded() / 10 }

    // MARK: Modelli pronti

    public struct Preset: Equatable {
        public let name: String          // chiave di traduzione (testo italiano)
        public let preferences: AppearancePreferences
    }

    public static let presets: [Preset] = [
        Preset(name: "Predefinito del sistema", preferences: .standard),
        Preset(name: "Chiaro", preferences: AppearancePreferences(backgroundHex: "FFFFFF", textHex: "1D1D1F")),
        Preset(name: "Scuro", preferences: AppearancePreferences(backgroundHex: "1E1E1E", textHex: "EDEDED")),
        Preset(name: "Contrasto alto", preferences: AppearancePreferences(backgroundHex: "000000", textHex: "FFFFFF")),
        Preset(name: "Seppia", preferences: AppearancePreferences(backgroundHex: "F4ECD8", textHex: "433422")),
        Preset(name: "Notte (rosso, per il set al buio)", preferences: AppearancePreferences(backgroundHex: "120000", textHex: "FF5A4D")),
    ]

    // MARK: Salvataggio

    public static let defaultsKey = "appearancePreferences"

    public static func load(from defaults: UserDefaults = .standard) -> AppearancePreferences {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(AppearancePreferences.self, from: data) else { return .standard }
        // si rinormalizza: un valore rovinato non deve mai produrre un'interfaccia illeggibile
        return AppearancePreferences(backgroundHex: decoded.backgroundHex, textHex: decoded.textHex, fontName: decoded.fontName, sizeScale: decoded.sizeScale)
    }

    public func save(to defaults: UserDefaults = .standard) {
        if isStandard { defaults.removeObject(forKey: Self.defaultsKey); return }
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
