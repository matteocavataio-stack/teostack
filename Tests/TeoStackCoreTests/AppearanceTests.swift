import XCTest
@testable import TeoStackCore

final class AppearanceTests: XCTestCase {
    func testHexNormalizationAndRGB() {
        XCTAssertEqual(AppearancePreferences.normalized("#1a2b3c"), "1A2B3C")
        XCTAssertEqual(AppearancePreferences.normalized(" ff00aa "), "FF00AA")
        for bad in ["", "12345", "1234567", "GG0000", "#12 456", nil] { XCTAssertNil(AppearancePreferences.normalized(bad), "\(bad ?? "nil")") }
        let c = AppearancePreferences.rgb("FF8000")
        XCTAssertEqual(c?.r, 1); XCTAssertEqual(c!.g, 128.0 / 255, accuracy: 1e-9); XCTAssertEqual(c?.b, 0)
        XCTAssertEqual(AppearancePreferences.hex(r: 1, g: 0.5, b: 0), "FF8000")
        XCTAssertEqual(AppearancePreferences.hex(r: 2, g: -1, b: 0.2), "FF0033", "fuori scala: limitato")
    }

    func testLuminanceContrastAndDarkDetection() {
        XCTAssertEqual(AppearancePreferences.luminance("FFFFFF")!, 1, accuracy: 1e-9)
        XCTAssertEqual(AppearancePreferences.luminance("000000")!, 0, accuracy: 1e-9)
        XCTAssertEqual(AppearancePreferences.contrast("000000", "FFFFFF")!, 21, accuracy: 1e-6)
        XCTAssertEqual(AppearancePreferences(backgroundHex: "1E1E1E").backgroundIsDark, true)
        XCTAssertEqual(AppearancePreferences(backgroundHex: "F4ECD8").backgroundIsDark, false)
        XCTAssertNil(AppearancePreferences.standard.backgroundIsDark, "sfondo di sistema: nessuna scelta forzata")
        XCTAssertTrue(AppearancePreferences(backgroundHex: "202020", textHex: "262626").lowContrast)
        XCTAssertFalse(AppearancePreferences(backgroundHex: "000000", textHex: "FFFFFF").lowContrast)
        XCTAssertFalse(AppearancePreferences(backgroundHex: "000000").lowContrast, "senza colore delle scritte non c'è un confronto")
    }

    func testSizeScaleIsClampedAndSizesFollowIt() {
        XCTAssertEqual(AppearancePreferences(sizeScale: 5).sizeScale, 1.5)
        XCTAssertEqual(AppearancePreferences(sizeScale: 0.1).sizeScale, 0.8)
        XCTAssertEqual(AppearancePreferences(sizeScale: .nan).sizeScale, 1)
        XCTAssertEqual(AppearancePreferences(sizeScale: 1.23).sizeScale, 1.25, "a passi di 0,05")
        let p = AppearancePreferences(sizeScale: 1.5)
        XCTAssertEqual(p.size(.callout), 18)
        XCTAssertEqual(AppearancePreferences.standard.size(.caption), 10)
        XCTAssertEqual(AppearancePreferences.standard.size(.headline), 13)
    }

    func testBlankFontIsSystemAndSaveLoadRoundTrip() throws {
        XCTAssertNil(AppearancePreferences(fontName: "  ").fontName)
        let defaults = UserDefaults(suiteName: "teostack-appearance-\(UUID().uuidString)")!
        XCTAssertTrue(AppearancePreferences.load(from: defaults).isStandard)
        let p = AppearancePreferences(backgroundHex: "#101820", textHex: "f2aa4c", fontName: "Avenir Next", sizeScale: 1.1)
        p.save(to: defaults)
        XCTAssertEqual(AppearancePreferences.load(from: defaults), p)
        XCTAssertEqual(AppearancePreferences.load(from: defaults).backgroundHex, "101820")
        AppearancePreferences.standard.save(to: defaults)
        XCTAssertNil(defaults.data(forKey: AppearancePreferences.defaultsKey), "i valori predefiniti non si salvano")
        defaults.set(Data("{\"backgroundHex\":\"zz\",\"sizeScale\":99}".utf8), forKey: AppearancePreferences.defaultsKey)
        let broken = AppearancePreferences.load(from: defaults)
        XCTAssertNil(broken.backgroundHex); XCTAssertEqual(broken.sizeScale, 1.5)
        defaults.set(Data("non json".utf8), forKey: AppearancePreferences.defaultsKey)
        XCTAssertTrue(AppearancePreferences.load(from: defaults).isStandard)
    }

    func testEveryPresetNameIsTranslatedInEveryLanguage() {
        for preset in AppearancePreferences.presets {
            for language in AppLanguage.allCases where language != .italian {
                XCTAssertNotNil(Loc.translation(preset.name, in: language), "\(preset.name) manca in \(language)")
            }
        }
    }

    func testPresetsAreReadable() {
        XCTAssertEqual(AppearancePreferences.presets.first?.preferences, .standard)
        for preset in AppearancePreferences.presets {
            XCTAssertFalse(preset.preferences.lowContrast, preset.name)
            if let c = preset.preferences.backgroundHex, let t = preset.preferences.textHex {
                XCTAssertGreaterThanOrEqual(AppearancePreferences.contrast(c, t)!, 4.5, preset.name)
            }
        }
        XCTAssertEqual(Set(AppearancePreferences.presets.map(\.name)).count, AppearancePreferences.presets.count)
    }
}
