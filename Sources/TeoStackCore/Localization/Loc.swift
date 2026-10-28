import Foundation

/// Lingue dell'interfaccia. Italiano è la lingua di origine dei testi: le altre sono tradotte in `Strings*.swift`.
public enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case italian = "it"
    case english = "en"
    case spanish = "es"
    case catalan = "ca"

    public var id: String { rawValue }

    /// Nome della lingua scritto nella lingua stessa (così si riconosce anche se l'interfaccia è in una lingua che non si capisce).
    public var displayName: String {
        switch self {
        case .italian: return "Italiano"
        case .english: return "English"
        case .spanish: return "Castellano"
        case .catalan: return "Català"
        }
    }

    public var locale: Locale { Locale(identifier: rawValue) }

    /// Lingua da usare al primo avvio: quella del sistema se è tra le quattro, altrimenti italiano.
    public static func fromSystem(_ preferred: [String] = Locale.preferredLanguages) -> AppLanguage {
        for tag in preferred {
            let code = tag.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
            if let language = AppLanguage(rawValue: code) { return language }
        }
        return .italian
    }
}

/// Traduzione dei testi. La chiave è il testo italiano; i segnaposto sono `{0}`, `{1}`… (così l'ordine può cambiare da lingua a lingua).
/// Un testo senza traduzione si mostra in italiano, mai vuoto.
public enum Loc {
    public static let defaultsKey = "appLanguage"

    private static let lock = NSLock()
    private static var current: AppLanguage = .italian

    public static var language: AppLanguage {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }

    /// Lingua salvata nelle impostazioni (o, se non c'è, quella del sistema).
    public static func savedLanguage(_ defaults: UserDefaults = .standard) -> AppLanguage {
        if let raw = defaults.string(forKey: defaultsKey), let language = AppLanguage(rawValue: raw) { return language }
        return AppLanguage.fromSystem()
    }

    public static func save(_ language: AppLanguage, _ defaults: UserDefaults = .standard) {
        defaults.set(language.rawValue, forKey: defaultsKey)
    }

    /// Tutte le traduzioni, per lingua: chiave (testo italiano) → testo tradotto.
    static let tables: [AppLanguage: [String: String]] = {
        var all: [AppLanguage: [String: String]] = [.english: [:], .spanish: [:], .catalan: [:]]
        for (it, en, es, ca) in LocStrings.all {
            all[.english]?[it] = en
            all[.spanish]?[it] = es
            all[.catalan]?[it] = ca
        }
        return all
    }()

    /// Traduzione di `key` nella lingua indicata; nil se manca (per l'italiano la chiave stessa è il testo).
    public static func translation(_ key: String, in language: AppLanguage) -> String? {
        language == .italian ? key : tables[language]?[key]
    }

    public static func t(_ key: String, in language: AppLanguage, args: [Any] = []) -> String {
        var text = translation(key, in: language) ?? key
        for (i, arg) in args.enumerated() { text = text.replacingOccurrences(of: "{\(i)}", with: String(describing: arg)) }
        return text
    }

    public static func t(_ key: String, _ args: Any...) -> String {
        t(key, in: language, args: args)
    }

    /// Segnaposto presenti in un testo (per controllare che le traduzioni li conservino tutti).
    public static func placeholders(in text: String) -> [String] {
        var found: [String] = []
        var i = text.startIndex
        while let open = text[i...].firstIndex(of: "{") {
            guard let close = text[open...].firstIndex(of: "}") else { break }
            let inner = text[text.index(after: open)..<close]
            if !inner.isEmpty, inner.allSatisfy(\.isNumber) { found.append("{\(inner)}") }
            i = text.index(after: close)
        }
        return found.sorted()
    }
}

/// Scorciatoia per i testi dell'interfaccia: `tr("Avvia")`, `tr("{0} file", count)`.
public func tr(_ key: String, _ args: Any...) -> String {
    Loc.t(key, in: Loc.language, args: args)
}

/// Testo traducibile salvato come chiave + parametri (per ricomporlo nella lingua corrente).
public struct LocText: Codable, Equatable {
    public var key: String
    public var args: [String]

    public init(_ key: String, _ args: Any...) {
        self.key = key
        self.args = args.map { String(describing: $0) }
    }

    public var text: String { Loc.t(key, in: Loc.language, args: args) }
}

/// Testi di una voce di cronologia in forma traducibile.
struct EventTexts: Codable, Equatable {
    var title: LocText
    var detail: LocText?
}
