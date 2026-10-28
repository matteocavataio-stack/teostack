import Foundation

/// Stato di un file su una singola destinazione.
public enum DestFileStatus: String, Codable, Equatable {
    case pending      // non ancora copiato
    case copying      // copia in corso
    case copied       // copiato, NON ancora verificato (non è un OK)
    case verifying    // verifica in corso
    case ok           // riletto dal disco e XXH64 identico alla sorgente
    case mismatch     // riletto dal disco ma XXH64 diverso dalla sorgente
    case error        // errore di lettura/scrittura/spazio/disco

    public var label: String {
        switch self {
        case .pending: return tr("In attesa")
        case .copying: return tr("Copia")
        case .copied: return tr("Da verificare")
        case .verifying: return tr("Verifica")
        case .ok: return "OK"
        case .mismatch: return "MISMATCH"
        case .error: return tr("ERRORE")
        }
    }
}

public struct SourceFile: Codable, Hashable, Identifiable {
    public var id: String { relativePath }
    public let relativePath: String
    public let size: Int64
    public let modificationDate: Date
    public let creationDate: Date?

    public var name: String { (relativePath as NSString).lastPathComponent }
    public var folder: String { (relativePath as NSString).deletingLastPathComponent }
}

public struct SourceDirectory: Codable, Hashable {
    public let relativePath: String
    public let modificationDate: Date
    public let creationDate: Date?
}

public struct SkippedItem: Codable, Hashable {
    public let relativePath: String
    public let reason: String
}

public struct ScanResult {
    public var root: URL
    public var files: [SourceFile]
    public var directories: [SourceDirectory]
    public var skipped: [SkippedItem]
    public var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }
}

public struct OffloadJob: Codable {
    /// Numero massimo di destinazioni contemporanee. Il motore gestisce un numero qualsiasi di scritture in parallelo;
    /// oltre questo limite la lettura/scrittura sui dischi rallenterebbe troppo senza vantaggi pratici.
    public static let maxDestinations = 8

    public var id: UUID
    public var sourceURL: URL
    /// Cartelle finali di destinazione (1...`maxDestinations`). Il contenuto della sorgente viene copiato DENTRO ciascuna.
    public var destinationRoots: [URL]
    /// Cartelle base scelte dall'utente (il disco): devono esistere; sotto di esse le cartelle mancanti vengono create.
    /// Se assente, la cartella di destinazione o la sua cartella superiore deve già esistere.
    public var destinationBases: [URL]?
    public var createdAt: Date

    public init(id: UUID = UUID(), sourceURL: URL, destinationRoots: [URL], destinationBases: [URL]? = nil, createdAt: Date = Date()) {
        self.id = id
        self.sourceURL = sourceURL
        self.destinationRoots = destinationRoots
        self.destinationBases = destinationBases
        self.createdAt = createdAt
    }
}

public struct DestFileResult: Codable, Equatable {
    public var status: DestFileStatus = .pending
    /// XXH64 riletto dalla destinazione (solo se la rilettura è avvenuta).
    public var destHash: String?
    public var message: String?
}

public struct FileResult: Codable {
    public var relativePath: String
    public var size: Int64
    /// XXH64 calcolato sulla sorgente durante l'unica lettura. nil se la sorgente non è stata letta con successo.
    public var sourceHash: String?
    public var destinations: [DestFileResult]
    /// Data di modifica del file sulla sorgente (la stessa viene riportata sulle copie).
    public var modificationDate: Date?
}

public enum OffloadOutcome: String, Codable {
    case completed       // tutti i file elaborati (controllare `allOK`)
    case cancelled
    case preflightFailed
}

public struct OffloadResult {
    public var job: OffloadJob
    public var outcome: OffloadOutcome
    public var files: [FileResult]
    public var preflightErrors: [String]
    public var destinationErrors: [String?]      // errore fatale per destinazione (disco pieno, scollegato…)
    public var skippedAlreadyVerified: Int       // file saltati in "Riprendi" perché già OK
    public var elapsed: TimeInterval

    /// true solo se OGNI file è OK su OGNI destinazione.
    public var allOK: Bool {
        outcome == .completed
            && !files.isEmpty
            && destinationErrors.allSatisfy { $0 == nil }
            && files.allSatisfy { $0.destinations.allSatisfy { $0.status == .ok } }
    }

    public func count(_ status: DestFileStatus, destination d: Int) -> Int {
        files.filter { d < $0.destinations.count && $0.destinations[d].status == status }.count
    }
}

public enum OffloadPhase: String, Codable {
    case idle, preflight, copying, verifying, finished
    public var label: String {
        switch self {
        case .idle: return tr("Pronto")
        case .preflight: return tr("Controlli preliminari")
        case .copying: return tr("Copia")
        case .verifying: return tr("Verifica")
        case .finished: return tr("Terminato")
        }
    }
}

public struct DestinationProgress {
    public var root: URL
    public var totalBytes: Int64 = 0       // byte da scrivere/verificare su questa destinazione
    public var writtenBytes: Int64 = 0
    public var verifiedBytes: Int64 = 0
    public var writeSpeed: Double = 0      // byte/s (media mobile)
    public var verifySpeed: Double = 0     // byte/s (media mobile)
    public var eta: TimeInterval?          // della fase corrente
    public var okCount = 0
    public var mismatchCount = 0
    public var errorCount = 0
    public var fatalError: String?
}

public struct OffloadSnapshot {
    public var phase: OffloadPhase = .idle
    public var currentFile: String?
    public var totalBytes: Int64 = 0       // byte da elaborare per ciascuna fase
    public var readBytes: Int64 = 0
    public var readSpeed: Double = 0       // byte/s (media mobile)
    public var filesTotal = 0
    public var filesCopied = 0
    public var destinations: [DestinationProgress] = []
    public var elapsed: TimeInterval = 0
    public var eta: TimeInterval?          // della fase corrente

    public init() {}
}

public struct FileUpdate {
    public var fileIndex: Int
    public var destinationIndex: Int
    public var status: DestFileStatus
    public var message: String?
}
