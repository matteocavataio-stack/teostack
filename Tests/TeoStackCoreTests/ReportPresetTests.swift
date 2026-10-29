import XCTest
@testable import TeoStackCore

final class ReportPresetTests: XCTestCase {
    private func store() -> ReportPresetStore {
        ReportPresetStore(defaults: UserDefaults(suiteName: "teostack-presets-\(UUID().uuidString)")!)
    }

    private var someColumns: [String] { Array(ReportColumnChoice.available.map(\.id).prefix(4)) }

    func testCreateListAndPersist() throws {
        let defaults = UserDefaults(suiteName: "teostack-presets-\(UUID().uuidString)")!
        let s = ReportPresetStore(defaults: defaults)
        XCTAssertTrue(s.all().isEmpty)
        let a = try s.create(name: "  Consegna produzione ", kinds: [.clips, .thumbnail], columnIDs: someColumns, operatorName: "Teo")
        _ = try s.create(name: "Backup giornaliero", kinds: [.shootingDay, .volume], columnIDs: [], operatorName: "")
        XCTAssertEqual(a.name, "Consegna produzione", "spazi ai bordi tolti")
        XCTAssertEqual(s.all().map(\.name), ["Backup giornaliero", "Consegna produzione"], "ordinati per nome")
        // un'altra istanza sulle stesse preferenze (riavvio dell'app) li ritrova
        let again = ReportPresetStore(defaults: defaults).all()
        XCTAssertEqual(again.count, 2)
        XCTAssertEqual(ReportPresetStore(defaults: defaults).preset(id: a.id)?.operatorName, "Teo")
    }

    func testNameRules() throws {
        let s = store()
        XCTAssertThrowsError(try s.create(name: "   ", kinds: [], columnIDs: [], operatorName: ""))
        XCTAssertThrowsError(try s.create(name: String(repeating: "x", count: 61), kinds: [], columnIDs: [], operatorName: ""))
        let p = try s.create(name: "Clips", kinds: [.clips], columnIDs: [], operatorName: "")
        XCTAssertThrowsError(try s.create(name: "clips", kinds: [], columnIDs: [], operatorName: "")) { XCTAssertEqual($0 as? ReportPresetError, .duplicateName("clips")) }
        let q = try s.create(name: "Altro", kinds: [], columnIDs: [], operatorName: "")
        XCTAssertThrowsError(try s.rename(id: q.id, to: "CLIPS"), "un profilo non prende il nome di un altro")
        XCTAssertNoThrow(try s.rename(id: p.id, to: "Clips"), "stesso nome dello stesso profilo: ammesso")
        try s.rename(id: q.id, to: "Consegna")
        XCTAssertEqual(s.preset(id: q.id)?.name, "Consegna")
        XCTAssertThrowsError(try s.rename(id: UUID(), to: "x")) { XCTAssertEqual($0 as? ReportPresetError, .notFound) }
    }

    func testUpdateAndDelete() throws {
        let s = store()
        let p = try s.create(name: "A", kinds: [.clips], columnIDs: someColumns, operatorName: "")
        try s.update(id: p.id, kinds: [.volume, .contactPrint], columnIDs: [], operatorName: "Luca")
        let u = try XCTUnwrap(s.preset(id: p.id))
        XCTAssertEqual(u.name, "A"); XCTAssertEqual(u.resolvedKinds, [.volume, .contactPrint]); XCTAssertEqual(u.operatorName, "Luca")
        XCTAssertThrowsError(try s.update(id: UUID(), kinds: [], columnIDs: [], operatorName: ""))
        s.delete(id: p.id)
        XCTAssertTrue(s.all().isEmpty)
        s.delete(id: p.id)   // già eliminato: nessun errore
    }

    func testResolvedIgnoresUnknownValuesAndMatches() {
        let p = ReportPreset(name: "x", kinds: ["clips", "futureReport", "volume"], columnIDs: ["camera", "colonnaInesistente"], operatorName: "T")
        XCTAssertEqual(p.resolvedKinds, [.clips, .volume])
        XCTAssertEqual(p.resolvedColumnIDs.contains("colonnaInesistente"), false)
        XCTAssertTrue(p.matches(kinds: [.volume, .clips], columnIDs: p.resolvedColumnIDs, operatorName: "T"))
        XCTAssertFalse(p.matches(kinds: [.clips], columnIDs: p.resolvedColumnIDs, operatorName: "T"))
        XCTAssertFalse(p.matches(kinds: [.volume, .clips], columnIDs: p.resolvedColumnIDs, operatorName: "Altro"))
    }

    func testExportImportBetweenMacsNeverOverwrites() throws {
        let a = store(), b = store()
        _ = try a.create(name: "Consegna", kinds: [.clips], columnIDs: someColumns, operatorName: "Teo")
        _ = try a.create(name: "Backup", kinds: [.volume], columnIDs: [], operatorName: "")
        let data = try a.exportData()
        XCTAssertEqual(try b.importData(data), 2)
        XCTAssertEqual(b.all().map(\.name), ["Backup", "Consegna"])
        XCTAssertNotEqual(b.all().first?.id, a.all().first?.id, "nuovi identificatori")
        // importando di nuovo: nessun profilo viene sovrascritto, i nuovi prendono un nome diverso
        XCTAssertEqual(try b.importData(data), 2)
        XCTAssertEqual(b.all().map(\.name).sorted(), ["Backup", "Backup 2", "Consegna", "Consegna 2"])
        XCTAssertThrowsError(try b.importData(Data("non json".utf8))) { XCTAssertEqual($0 as? ReportPresetError, .unreadableFile) }
        XCTAssertThrowsError(try b.importData(Data("[]".utf8)))
        XCTAssertEqual(b.all().count, 4)
    }
}
