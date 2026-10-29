import Foundation

/// Profilo di esportazione dei report: quali report creare, quali colonne stampare e l'operatore. Si salva con un nome e si richiama quando serve.
public struct ReportPreset: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    /// `ReportKind.rawValue` dei report da creare.
    public var kinds: [String]
    /// Identificatori delle colonne dei report Clips e Thumbnail (`ClipColumn.id`).
    public var columnIDs: [String]
    public var operatorName: String

    public init(id: UUID = UUID(), name: String, kinds: [String], columnIDs: [String], operatorName: String = "") {
        self.id = id
        self.name = name
        self.kinds = kinds
        self.columnIDs = columnIDs
        self.operatorName = operatorName
    }

    /// Report del profilo ancora validi (un nome sconosciuto, per esempio di una versione più recente, si ignora), nell'ordine standard.
    public var resolvedKinds: [ReportKind] {
        let wanted = Set(kinds)
        return ReportKind.allCases.filter { wanted.contains($0.rawValue) }
    }

    /// Colonne del profilo ancora disponibili nei report, nell'ordine standard.
    public var resolvedColumnIDs: [String] {
        let wanted = Set(columnIDs)
        return ReportColumnChoice.available.map(\.id).filter { wanted.contains($0) }
    }

    /// Le scelte attuali coincidono con quelle del profilo? (serve a mostrare «modificato»)
    public func matches(kinds currentKinds: Set<ReportKind>, columnIDs currentColumns: [String], operatorName currentOperator: String) -> Bool {
        Set(resolvedKinds) == currentKinds && Set(resolvedColumnIDs) == Set(currentColumns) && operatorName == currentOperator
    }
}

public enum ReportPresetError: Error, CustomStringConvertible, Equatable {
    case invalidName
    case duplicateName(String)
    case notFound
    case unreadableFile

    public var description: String {
        switch self {
        case .invalidName: return tr("Il nome del profilo non può essere vuoto né più lungo di {0} caratteri.", ReportPresetStore.maxNameLength)
        case .duplicateName(let n): return tr("Esiste già un profilo chiamato «{0}».", n)
        case .notFound: return tr("Profilo non trovato.")
        case .unreadableFile: return tr("Il file non contiene profili validi.")
        }
    }
}

/// Elenco dei profili salvati (nelle preferenze dell'app). Mai sovrascrive un profilo con un altro dello stesso nome.
public struct ReportPresetStore {
    public static let maxNameLength = 60
    public static let defaultsKey = "reportPresets"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Ordinati per nome.
    public func all() -> [ReportPreset] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let list = try? JSONDecoder().decode([ReportPreset].self, from: data) else { return [] }
        return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func preset(id: UUID) -> ReportPreset? { all().first { $0.id == id } }

    static func cleanName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= maxNameLength else { throw ReportPresetError.invalidName }
        return name
    }

    private func write(_ list: [ReportPreset]) {
        if list.isEmpty { defaults.removeObject(forKey: Self.defaultsKey); return }
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    private func isTaken(_ name: String, except id: UUID?, in list: [ReportPreset]) -> Bool {
        list.contains { $0.id != id && $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    /// Nuovo profilo con le scelte attuali.
    @discardableResult
    public func create(name: String, kinds: [ReportKind], columnIDs: [String], operatorName: String) throws -> ReportPreset {
        let clean = try Self.cleanName(name)
        var list = all()
        guard !isTaken(clean, except: nil, in: list) else { throw ReportPresetError.duplicateName(clean) }
        let preset = ReportPreset(name: clean, kinds: kinds.map(\.rawValue), columnIDs: columnIDs, operatorName: operatorName)
        list.append(preset)
        write(list)
        return preset
    }

    /// Aggiorna le scelte di un profilo esistente (il nome resta).
    public func update(id: UUID, kinds: [ReportKind], columnIDs: [String], operatorName: String) throws {
        var list = all()
        guard let i = list.firstIndex(where: { $0.id == id }) else { throw ReportPresetError.notFound }
        list[i].kinds = kinds.map(\.rawValue)
        list[i].columnIDs = columnIDs
        list[i].operatorName = operatorName
        write(list)
    }

    public func rename(id: UUID, to name: String) throws {
        let clean = try Self.cleanName(name)
        var list = all()
        guard let i = list.firstIndex(where: { $0.id == id }) else { throw ReportPresetError.notFound }
        guard !isTaken(clean, except: id, in: list) else { throw ReportPresetError.duplicateName(clean) }
        list[i].name = clean
        write(list)
    }

    public func delete(id: UUID) {
        write(all().filter { $0.id != id })
    }

    // MARK: Scambio tra Mac (file JSON)

    public func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(all())
    }

    /// Aggiunge i profili di un file esportato. Un profilo con un nome già presente non sostituisce quello esistente: prende un nome diverso («… 2»).
    /// Restituisce quanti ne ha aggiunti.
    @discardableResult
    public func importData(_ data: Data) throws -> Int {
        guard let incoming = try? JSONDecoder().decode([ReportPreset].self, from: data), !incoming.isEmpty else { throw ReportPresetError.unreadableFile }
        var list = all()
        var added = 0
        for var preset in incoming {
            guard let base = try? Self.cleanName(preset.name) else { continue }
            var name = base
            var n = 2
            while isTaken(name, except: nil, in: list) {
                name = "\(String(base.prefix(Self.maxNameLength - 4))) \(n)"
                n += 1
            }
            preset.name = name
            preset.id = UUID()
            list.append(preset)
            added += 1
        }
        guard added > 0 else { throw ReportPresetError.unreadableFile }
        write(list)
        return added
    }
}
