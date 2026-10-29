import XCTest
@testable import TeoStackCore

final class ManualTests: XCTestCase {
    private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    func testManualIsAValidMultiPagePDFWithCoverTOCAndFooters() throws {
        let data = ManualPDF.render(version: "9.9.9", date: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(text(data.prefix(8)).hasPrefix("%PDF-"))
        XCTAssertTrue(text(data.suffix(64)).contains("%%EOF"))
        let t = text(data)
        let pages = t.components(separatedBy: "/Type /Page\n").count - 1 + (t.components(separatedBy: "/Type /Page ").count - 1)
        XCTAssertGreaterThan(pages, 8, "un manuale completo ha molte pagine")
        XCTAssertGreaterThan(ManualPDF.headingCount(), 30)
        XCTAssertGreaterThan(data.count, 20_000)
    }

    func testEveryFeatureOfTheAppIsDocumented() {
        let all = ManualContent.blocks.map { block -> String in
            switch block {
            case .h1(let s), .h2(let s), .p(let s), .note(let s), .warning(let s): return s
            case .bullets(let a), .steps(let a), .code(let a): return a.joined(separator: " ")
            case .table(let h, let rows, _): return (h + rows.flatMap { $0 }).joined(separator: " ")
            }
        }.joined(separator: "\n")
        for term in ["Offload", "XXH64", "ASC MHL", "Importa media", "Leggi metadata", "Crea anteprime", "Esporta report", "Profilo", "Salva come",
                     "Percorsi salvati", "Schede collegate", "Espelli sorgente", "Svuota la sorgente", "Riprendi", "Importa log", "Esporta metadata", "ALE",
                     "Impostazioni", "Lingua", "art-cmd", "ExifTool", "ffprobe", "N/D", "MISMATCH", "teostackpart", "Shooting Day", "Contact Print",
                     "Ripristina ordine e larghezze", "Comando + virgola", "Verifica durante la copia", "Sovrascrivi"] {
            XCTAssertTrue(all.contains(term), "il manuale non parla di «\(term)»")
        }
    }

    func testManualNeverPromisesWhatTheAppDoesNotDo() {
        let all = ManualContent.blocks.map { "\($0)" }.joined()
        XCTAssertTrue(all.contains("NON cancella nulla dalla scheda"))
        XCTAssertTrue(all.contains("Non transcodifica"))
    }

    func testSectionNumbering() {
        let h1 = ManualContent.blocks.compactMap { b -> String? in if case .h1(let s) = b { return s }; return nil }
        for (i, t) in h1.enumerated() { XCTAssertTrue(t.hasPrefix("\(i + 1). "), t) }
    }
}

extension ManualTests {
    private func plain(_ block: ManualBlock) -> [String] {
        switch block {
        case .h1(let s), .h2(let s), .p(let s), .note(let s), .warning(let s): return [s]
        case .bullets(let a), .steps(let a), .code(let a): return a
        case .table(let h, let rows, _): return h + rows.flatMap { $0 }
        }
    }

    /// Ogni testo italiano del manuale ha la traduzione in tutte le lingue, con gli stessi grassetti e la stessa struttura.
    func testEveryManualTextIsTranslatedInAllLanguages() {
        let italian = ManualContent.blocks
        for language in [AppLanguage.english, .spanish, .catalan] {
            let translated = ManualContent.blocks(for: language)
            XCTAssertEqual(translated.count, italian.count)
            XCTAssertEqual(ManualPDF.headingCount(for: language), ManualPDF.headingCount())
            for (a, b) in zip(italian, translated) {
                let pa = plain(a), pb = plain(b)
                XCTAssertEqual(pa.count, pb.count)
                for (x, y) in zip(pa, pb) {
                    // i comandi del Terminale non si traducono
                    if x.hasPrefix("mkdir ") || x.hasPrefix("unzip ") { continue }
                    XCTAssertNotNil(ManualStrings.tables[language]?[x], "[\(language.rawValue)] manca la traduzione di: \(x.prefix(60))")
                    XCTAssertEqual(x.components(separatedBy: "**").count, y.components(separatedBy: "**").count, "[\(language.rawValue)] grassetti diversi: \(x.prefix(60))")
                }
            }
        }
    }

    func testTranslatedManualsKeepSectionNumbering() {
        for language in AppLanguage.allCases {
            let h1 = ManualContent.blocks(for: language).compactMap { b -> String? in if case .h1(let s) = b { return s }; return nil }
            XCTAssertEqual(h1.count, 15)
            for (i, t) in h1.enumerated() { XCTAssertTrue(t.hasPrefix("\(i + 1). "), "[\(language.rawValue)] \(t)") }
        }
    }

    func testEveryLanguageRendersAValidPDFWithLocalizedCover() {
        for language in AppLanguage.allCases {
            let data = ManualPDF.render(language: language, version: "1.0", date: Date(timeIntervalSince1970: 1_800_000_000))
            XCTAssertTrue(text(data.prefix(8)).hasPrefix("%PDF-"), language.rawValue)
            XCTAssertGreaterThan(data.count, 20_000, language.rawValue)
        }
        XCTAssertEqual(ManualPDF.fileName(for: .italian), "TeoStackPro-Manuale.pdf")
        XCTAssertEqual(ManualPDF.fileName(for: .english), "TeoStackPro-Manual.pdf")
    }

    func testMovedSoundOptionIsDocumentedInSettings() {
        let it = ManualContent.blocks.flatMap { plain($0) }.joined(separator: "\n")
        XCTAssertTrue(it.contains("**Suono al termine**"))
    }

    /// Scrive il PDF dove indica TEOSTACK_MANUAL_OUT (per guardarlo a occhio durante lo sviluppo).
    func testWriteManualForInspection() throws {
        guard let out = ProcessInfo.processInfo.environment["TEOSTACK_MANUAL_OUT"] else { throw XCTSkip("solo per ispezione manuale") }
        let language = ProcessInfo.processInfo.environment["TEOSTACK_MANUAL_LANG"].flatMap { AppLanguage(rawValue: $0) } ?? .italian
        try ManualPDF.render(language: language, version: ProcessInfo.processInfo.environment["TEOSTACK_MANUAL_VERSION"] ?? AppInfo.version).write(to: URL(fileURLWithPath: out))
    }
}
