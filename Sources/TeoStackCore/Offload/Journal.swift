import Foundation

/// Registro persistente di un offload: serve a "Riprendi" e (fase progetti) a registrare l'offload nel bin.
public struct OffloadJournal: Codable {
    public enum State: String, Codable { case running, cancelled, completed }
    public var job: OffloadJob
    public var state: State
    public var files: [FileResult]
    public var updatedAt: Date

    /// Vero se il registro descrive un lavoro non concluso con tutti i file OK.
    public var isResumable: Bool {
        state != .completed || files.contains { $0.destinations.contains { $0.status != .ok } }
    }
}

public final class JournalStore {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("offload-\(id.uuidString).json")
    }

    public func save(_ journal: OffloadJournal) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(journal)
        try data.write(to: url(for: journal.job.id), options: .atomic)
    }

    public func load(id: UUID) throws -> OffloadJournal {
        try decode(url(for: id))
    }

    private func decode(_ url: URL) throws -> OffloadJournal {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(OffloadJournal.self, from: Data(contentsOf: url))
    }

    /// Il registro più recente non concluso (per il pulsante "Riprendi").
    public func latestResumable() -> OffloadJournal? {
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
        return items.filter { $0.lastPathComponent.hasPrefix("offload-") && $0.pathExtension == "json" }
            .compactMap { try? decode($0) }
            .filter { $0.isResumable }
            .max { $0.updatedAt < $1.updatedAt }
    }
}
