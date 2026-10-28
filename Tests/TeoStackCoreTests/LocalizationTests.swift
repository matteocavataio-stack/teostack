import XCTest
@testable import TeoStackCore

final class LocalizationTests: XCTestCase {
    override func tearDown() {
        Loc.language = .italian
    }

    /// Testi lunghi che in alcune lingue si scrivono come in italiano (parola identica o termine tecnico).
    private static let sameInEveryLanguageByDesign: Set<String> = ["Audio sample rate", "Copia {0}%  {1}"]

    /// Tutti i testi tradotti nel codice (`tr("…")`, `LocText("…")`), cercati nei sorgenti: ognuno deve avere la traduzione in ogni lingua.
    private func keysUsedInSources() throws -> [String: String] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let regex = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_.])(?:tr|LocText|Loc\.t)\(\s*"((?:[^"\\]|\\.)*)""#)
        var keys: [String: String] = [:]
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        for url in files where url.pathExtension == "swift" && !url.path.contains("/Localization/") {
            let text = try String(contentsOf: url, encoding: .utf8)
            for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let r = Range(m.range(at: 1), in: text) else { continue }
                let key = String(text[r]).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
                    .replacingOccurrences(of: "\\n", with: "\n")
                keys[key] = url.lastPathComponent
            }
        }
        return keys
    }

    func testEveryTextUsedInTheCodeIsTranslatedInEveryLanguage() throws {
        let keys = try keysUsedInSources()
        XCTAssertGreaterThan(keys.count, 250, "la ricerca dei testi nei sorgenti non funziona")
        for (key, file) in keys.sorted(by: { $0.key < $1.key }) {
            XCTAssertFalse(key.contains("\\("), "\(file): la chiave contiene un'interpolazione Swift, usare {0}: \(key)")
            for language in [AppLanguage.english, .spanish, .catalan] {
                XCTAssertNotNil(Loc.translation(key, in: language), "\(file): manca la traduzione \(language.rawValue) di «\(key)»")
            }
        }
    }

    func testClipColumnTitlesAreTranslated() {
        for column in ClipColumns.all {
            for language in [AppLanguage.english, .spanish, .catalan] {
                XCTAssertNotNil(Loc.translation(column.title, in: language), "colonna \(column.id): manca \(language.rawValue)")
            }
        }
    }

    func testTranslationsKeepAllPlaceholdersAndAreNotEmpty() {
        var seen = Set<String>()
        for (it, en, es, ca) in LocStrings.all {
            XCTAssertTrue(seen.insert(it).inserted, "chiave doppia: \(it)")
            for (language, text) in [("en", en), ("es", es), ("ca", ca)] {
                XCTAssertFalse(text.trimmingCharacters(in: .whitespaces).isEmpty, "\(language) vuota: \(it)")
                XCTAssertEqual(Loc.placeholders(in: text), Loc.placeholders(in: it), "\(language): segnaposto diversi in «\(it)» → «\(text)»")
            }
        }
    }

    func testTextsAreActuallyTranslated() {
        // «Avvia» → Start / Iniciar / Inicia: se una lingua mostrasse l'italiano la traduzione sarebbe saltata.
        Loc.language = .italian
        XCTAssertEqual(tr("Avvia"), "Avvia")
        Loc.language = .english
        XCTAssertEqual(tr("Avvia"), "Start")
        Loc.language = .spanish
        XCTAssertEqual(tr("Avvia"), "Iniciar")
        Loc.language = .catalan
        XCTAssertEqual(tr("Avvia"), "Inicia")
        // nelle altre tre lingue quasi nessun testo deve restare uguale all'italiano (sono ammessi nomi tecnici e sigle)
        for (language, index) in [(AppLanguage.english, 1), (.spanish, 2), (.catalan, 3)] {
            let same = LocStrings.all.filter { entry in
                let translated = [entry.0, entry.1, entry.2, entry.3][index]
                return translated == entry.0 && entry.0.contains(where: { $0.isLetter }) && entry.0.count > 14
                    && !Self.sameInEveryLanguageByDesign.contains(entry.0)   // termini che coincidono davvero (es. «Copia» in spagnolo)
            }
            XCTAssertTrue(same.isEmpty, "\(language.rawValue): testi lunghi rimasti in italiano: \(same.map { $0.0 })")
        }
    }

    func testPlaceholdersAreFilledInEveryLanguage() {
        for language in AppLanguage.allCases {
            Loc.language = language
            let text = tr("Servono da 1 a {0} destinazioni (selezionate: {1}).", 8, 9)
            XCTAssertTrue(text.contains("8") && text.contains("9") && !text.contains("{"), "\(language.rawValue): \(text)")
        }
        // un testo senza traduzione si mostra in italiano, mai vuoto
        Loc.language = .english
        XCTAssertEqual(tr("testo che non esiste {0}", 5), "testo che non esiste 5")
    }

    func testLanguageFromSystemAndPersistence() {
        XCTAssertEqual(AppLanguage.fromSystem(["es-ES", "en"]), .spanish)
        XCTAssertEqual(AppLanguage.fromSystem(["ca-ES"]), .catalan)
        XCTAssertEqual(AppLanguage.fromSystem(["it-IT"]), .italian)
        XCTAssertEqual(AppLanguage.fromSystem(["en_GB"]), .english)
        XCTAssertEqual(AppLanguage.fromSystem(["pt-BR", "ca"]), .catalan, "salta le lingue non supportate")
        XCTAssertEqual(AppLanguage.fromSystem(["fr-FR"]), .italian, "senza una lingua supportata resta l'italiano")
        XCTAssertEqual(AppLanguage.allCases.map(\.displayName), ["Italiano", "English", "Castellano", "Català"])

        let defaults = UserDefaults(suiteName: "teostack.loc.\(UUID().uuidString)")!
        Loc.save(.catalan, defaults)
        XCTAssertEqual(Loc.savedLanguage(defaults), .catalan)
    }

    func testClipColumnLabelsFollowTheLanguageButReportsStayTheSame() {
        let duration = ClipColumns.column(id: "duration")!
        Loc.language = .english
        XCTAssertEqual(duration.localizedTitle, "Duration")
        XCTAssertEqual(ClipColumns.notAvailable, "N/A")
        XCTAssertEqual(ClipColumns.reportNotAvailable, "N/D", "i report non cambiano con la lingua")
        Loc.language = .spanish
        XCTAssertEqual(duration.localizedTitle, "Duración")
        XCTAssertEqual(ClipColumns.statusLabel("error"), "ERROR")
    }

    func testStatusLabelsAndDiskErrorsAreTranslated() {
        Loc.language = .english
        XCTAssertEqual(DestFileStatus.verifying.label, "Verify")
        XCTAssertEqual(OffloadPhase.finished.label, "Finished")
        let message = DiskIOError(code: ENOSPC, operation: tr("Scrittura"), path: "/x").description
        XCTAssertEqual(message, "Write «/x»: not enough space on the disk")
        Loc.language = .catalan
        XCTAssertEqual(DiskIOError(code: ENODEV, operation: tr("Lettura"), path: "/x").description, "Lectura «/x»: el disc ja no està disponible (desconnectat?)")
    }
}
