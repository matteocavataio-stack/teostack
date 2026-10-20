import Foundation

public enum NodeKind: String, Codable {
    case library, day, folder, bin
}

public struct Project: Identifiable, Equatable {
    public let id: Int64
    public var name: String
    public var createdAt: Date
}

public struct ProjectSummary: Identifiable, Equatable {
    public let id: Int64
    public var name: String
    public var createdAt: Date
    public var clipCount: Int
}

/// Nodo dell'albero: Library → (giorno e/o sottocartelle, facoltativi) → bin.
public struct TreeNode: Identifiable, Equatable {
    public let id: Int64
    public let projectID: Int64
    public let parentID: Int64?
    public let kind: NodeKind
    public var name: String
    public var clipCount: Int
    public var children: [TreeNode]?      // nil per i bin (foglie): serve a SwiftUI per non mostrare la freccia
}

public struct OffloadRecord: Identifiable, Equatable {
    public let id: Int64
    public let jobID: UUID
    public let binID: Int64
    public var sourcePath: String
    public var destinations: [String]
    public var startedAt: Date
    public var finishedAt: Date?
    public var outcome: String          // running / completed / cancelled
    public var allOK: Bool
    public var totalBytes: Int64
}

/// Riga della tabella clip.
public struct ClipRecord: Identifiable, Equatable {
    public let id: Int64
    public let offloadID: Int64
    public let binID: Int64
    public var relativePath: String
    public var name: String
    public var size: Int64
    public var sourceHash: String?
    public var status: String                       // ok / mismatch / error / pending (aggregato sulle destinazioni)
    public var destinationStatuses: [String]
    public var isMedia: Bool
    public var metadata: [String: String]           // chiave campo → valore; assente = "N/D"
    public var offloadDate: Date
    public var binName: String
    public var dayName: String
    /// Data di modifica del file (dalla sorgente); nil per gli offload registrati prima che fosse salvata.
    public var modifiedAt: Date? = nil
}

/// Voce della cronologia di un progetto.
public struct HistoryEvent: Identifiable, Equatable {
    public enum Severity { case info, success, warning, error }

    public let id: Int64
    public let projectID: Int64
    public let date: Date
    public let kind: String
    public let title: String
    public let detail: String?

    public var severity: Severity {
        switch kind {
        case "offloadCompleted": return .success
        case "offloadProblems", "offloadNotStarted": return .error
        case "offloadCancelled", "nodeDeleted": return .warning
        default: return .info
        }
    }
}

/// Dove va un offload: su disco viene creata SOLO la cartella del bin = <base>/<Bin>.
/// Progetto, Library e giorno esistono nel programma ma non creano cartelle sui dischi.
public struct BinTarget: Equatable {
    public var projectID: Int64
    public var projectName: String
    /// Cartelle (giorno e sottocartelle) tra la Library e il bin; vuoto se il bin è direttamente nella Library.
    public var folderPath: [String]
    public var binID: Int64
    public var binName: String

    /// Posizione leggibile: «Progetto › Giorno › Cartella › Bin».
    public var displayPath: String { ([projectName] + folderPath + [binName]).joined(separator: " › ") }

    public func destinationRoot(under base: URL) -> URL {
        base.appendingPathComponent(binName, isDirectory: true)
    }
}

/// Dove verrà creato il bin di un nuovo offload (cartella scelta nella barra laterale).
public struct BinPlacement: Equatable {
    public var projectID: Int64
    public var projectName: String
    public var parentID: Int64
    public var parentPath: [String]

    public init(projectID: Int64, projectName: String, parentID: Int64, parentPath: [String]) {
        self.projectID = projectID; self.projectName = projectName; self.parentID = parentID; self.parentPath = parentPath
    }

    public var displayPath: String { ([projectName] + parentPath).joined(separator: " › ") }
}

public enum ProjectStoreError: Error, CustomStringConvertible, Equatable {
    case invalidName(String)
    case duplicateName(String)
    case notFound(String)
    case invalidOperation(String)
    case database(String)

    public var description: String {
        switch self {
        case .invalidName(let m), .duplicateName(let m), .notFound(let m), .invalidOperation(let m): return m
        case .database(let m): return "Errore del database: \(m)"
        }
    }
}

/// I nomi diventano cartelle su disco (anche exFAT/NTFS): vietati i caratteri non portabili.
public enum NameValidator {
    /// Nome di bin proposto a partire dalla sorgente (nome della scheda/cartella): sostituisce i caratteri non ammessi.
    public static func suggestedBinName(fromSource name: String) -> String {
        var out = ""
        for u in name.unicodeScalars { out.unicodeScalars.append(forbiddenCharacters.contains(u) ? "_" : u) }
        out = out.trimmingCharacters(in: .whitespaces)
        while out.hasPrefix(".") { out.removeFirst() }
        while out.hasSuffix(".") { out.removeLast() }
        return String(out.prefix(100))
    }

    public static let forbiddenCharacters = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)

    public static func validated(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { throw ProjectStoreError.invalidName("Il nome non può essere vuoto.") }
        if name.count > 100 { throw ProjectStoreError.invalidName("Il nome è troppo lungo (massimo 100 caratteri).") }
        if name.unicodeScalars.contains(where: { forbiddenCharacters.contains($0) }) {
            throw ProjectStoreError.invalidName("Il nome non può contenere / \\ : * ? \" < > |")
        }
        if name.hasPrefix(".") || name.hasSuffix(".") {
            throw ProjectStoreError.invalidName("Il nome non può iniziare o finire con un punto.")
        }
        return name
    }
}

/// Quali file contano come "clip" nei conteggi. Gli altri file (XML, ALE, sidecar…) vengono registrati ma non contati.
/// Elenco modificabile: è un valore predefinito, da confermare con la struttura reale delle schede.
public enum MediaClassifier {
    public static var mediaExtensions: Set<String> = ["ari", "arx", "mov", "mxf", "mp4"]
    /// Clip audio (nei report compaiono come «Audio Clips»).
    public static var audioExtensions: Set<String> = ["wav", "bwf", "aif", "aiff", "mp3", "m4a", "aac", "flac"]

    public static func isMedia(relativePath: String) -> Bool {
        mediaExtensions.contains((relativePath as NSString).pathExtension.lowercased())
    }
}

public enum NameSuggestions {
    /// "DAY01_20261016": numero progressivo + data.
    public static func dayName(existingDayCount: Int, date: Date = Date(), calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "DAY%02d_%04d%02d%02d", existingDayCount + 1, c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
