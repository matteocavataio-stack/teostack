import Foundation

/// Percorsi di destinazione salvati dall'utente (i dischi di backup che usa di solito), per sceglierli con un clic.
/// Si salvano solo i percorsi: nessun file viene toccato.
public struct SavedPathsStore {
    public static let defaultsKey = "savedDestinationPaths"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Percorsi salvati, nell'ordine in cui sono stati aggiunti.
    public var paths: [String] {
        defaults.stringArray(forKey: Self.defaultsKey) ?? []
    }

    /// Forma normalizzata (senza «..», «.» o barra finale) usata per riconoscere due percorsi uguali.
    public static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    public func contains(_ path: String) -> Bool {
        let wanted = Self.normalized(path)
        return paths.contains { Self.normalized($0) == wanted }
    }

    /// Aggiunge il percorso se non c'è già. Restituisce true se è stato aggiunto.
    @discardableResult
    public func add(_ path: String) -> Bool {
        guard !path.isEmpty, !contains(path) else { return false }
        defaults.set(paths + [Self.normalized(path)], forKey: Self.defaultsKey)
        return true
    }

    public func remove(_ path: String) {
        let unwanted = Self.normalized(path)
        defaults.set(paths.filter { Self.normalized($0) != unwanted }, forKey: Self.defaultsKey)
    }

    /// Il percorso esiste ed è una cartella (un disco scollegato non è disponibile).
    public static func isAvailable(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
