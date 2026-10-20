import Foundation
import GRDB

/// Database locale (SQLite via GRDB): Progetto → Library → cartelle giorno → bin, offload e clip.
/// Cancellare progetti, giorni o bin elimina SOLO i record del database, mai file sul disco.
public final class ProjectStore {
    private let db: DatabaseQueue

    /// `path == nil` crea un database in memoria (test).
    public init(path: String?) throws {
        do {
            if let path {
                try FileManager.default.createDirectory(
                    atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                db = try DatabaseQueue(path: path)
            } else {
                db = try DatabaseQueue()
            }
            try ProjectStore.migrator.migrate(db)
        } catch {
            throw ProjectStoreError.database("\(error)")
        }
    }

    public static func defaultDatabasePath() -> String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("TeoStackXt/teostack.sqlite").path
    }

    // MARK: Schema

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE project (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL UNIQUE COLLATE NOCASE,
                    createdAt REAL NOT NULL
                );
                CREATE TABLE node (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    projectID INTEGER NOT NULL REFERENCES project(id) ON DELETE CASCADE,
                    parentID INTEGER REFERENCES node(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL,
                    name TEXT NOT NULL COLLATE NOCASE,
                    createdAt REAL NOT NULL,
                    UNIQUE(parentID, name)
                );
                CREATE INDEX node_project ON node(projectID);
                CREATE TABLE offload (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    jobID TEXT NOT NULL UNIQUE,
                    binID INTEGER NOT NULL REFERENCES node(id) ON DELETE CASCADE,
                    sourcePath TEXT NOT NULL,
                    destinationsJSON TEXT NOT NULL,
                    startedAt REAL NOT NULL,
                    finishedAt REAL,
                    outcome TEXT NOT NULL,
                    allOK INTEGER NOT NULL DEFAULT 0,
                    totalBytes INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX offload_bin ON offload(binID);
                CREATE TABLE clip (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    offloadID INTEGER NOT NULL REFERENCES offload(id) ON DELETE CASCADE,
                    binID INTEGER NOT NULL REFERENCES node(id) ON DELETE CASCADE,
                    relativePath TEXT NOT NULL,
                    name TEXT NOT NULL,
                    size INTEGER NOT NULL,
                    sourceHash TEXT,
                    status TEXT NOT NULL,
                    destStatusJSON TEXT NOT NULL,
                    isMedia INTEGER NOT NULL,
                    metadataJSON TEXT NOT NULL DEFAULT '{}',
                    UNIQUE(offloadID, relativePath)
                );
                CREATE INDEX clip_bin ON clip(binID);
                """)
        }
        return m
    }

    // MARK: Utilità

    private func wrap<T>(_ body: () throws -> T) throws -> T {
        do { return try body() }
        catch let e as ProjectStoreError { throw e }
        catch { throw ProjectStoreError.database("\(error)") }
    }

    private static func date(_ v: Double) -> Date { Date(timeIntervalSince1970: v) }

    private static func json<T: Encodable>(_ value: T) -> String {
        (try? String(data: JSONEncoder().encode(value), encoding: .utf8)) ?? "[]"
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ text: String, default fallback: T) -> T {
        (try? JSONDecoder().decode(type, from: Data(text.utf8))) ?? fallback
    }

    // MARK: Progetti

    @discardableResult
    public func createProject(name: String, createdAt: Date = Date()) throws -> Project {
        let name = try NameValidator.validated(name)
        return try wrap {
            try db.write { db in
                if try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM project WHERE name = ?", arguments: [name]) ?? 0 > 0 {
                    throw ProjectStoreError.duplicateName("Esiste già un progetto chiamato «\(name)».")
                }
                try db.execute(sql: "INSERT INTO project(name, createdAt) VALUES (?, ?)",
                               arguments: [name, createdAt.timeIntervalSince1970])
                let id = db.lastInsertedRowID
                try db.execute(sql: "INSERT INTO node(projectID, parentID, kind, name, createdAt) VALUES (?, NULL, 'library', 'Library', ?)",
                               arguments: [id, createdAt.timeIntervalSince1970])
                return Project(id: id, name: name, createdAt: createdAt)
            }
        }
    }

    public func renameProject(id: Int64, to newName: String) throws {
        let name = try NameValidator.validated(newName)
        try wrap {
            try db.write { db in
                if try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM project WHERE name = ? AND id <> ?", arguments: [name, id]) ?? 0 > 0 {
                    throw ProjectStoreError.duplicateName("Esiste già un progetto chiamato «\(name)».")
                }
                try db.execute(sql: "UPDATE project SET name = ? WHERE id = ?", arguments: [name, id])
                if db.changesCount == 0 { throw ProjectStoreError.notFound("Progetto non trovato.") }
            }
        }
    }

    public func deleteProject(id: Int64) throws {
        try wrap { try db.write { db in try db.execute(sql: "DELETE FROM project WHERE id = ?", arguments: [id]) } }
    }

    public func projects() throws -> [ProjectSummary] {
        try wrap {
            try db.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT p.id, p.name, p.createdAt,
                      (SELECT COUNT(*) FROM clip c JOIN node n ON n.id = c.binID
                        WHERE n.projectID = p.id AND c.isMedia = 1 AND c.status = 'ok') AS clips
                    FROM project p ORDER BY p.createdAt DESC, p.id DESC
                    """).map {
                    ProjectSummary(id: $0["id"], name: $0["name"], createdAt: ProjectStore.date($0["createdAt"]), clipCount: $0["clips"])
                }
            }
        }
    }

    // MARK: Albero

    /// Restituisce la Library del progetto con giorni e bin e i conteggi clip (solo media con tutte le destinazioni OK).
    public func tree(projectID: Int64) throws -> TreeNode {
        try wrap {
            try db.read { db in
                let rows = try Row.fetchAll(db, sql: "SELECT id, parentID, kind, name FROM node WHERE projectID = ? ORDER BY name COLLATE NOCASE", arguments: [projectID])
                let counts = try Row.fetchAll(db, sql: """
                    SELECT c.binID AS binID, COUNT(*) AS n FROM clip c JOIN node b ON b.id = c.binID
                    WHERE b.projectID = ? AND c.isMedia = 1 AND c.status = 'ok' GROUP BY c.binID
                    """, arguments: [projectID])
                var countByBin: [Int64: Int] = [:]
                for r in counts { countByBin[r["binID"]] = r["n"] }
                struct Raw { let id: Int64; let parent: Int64?; let kind: NodeKind; let name: String }
                let raws: [Raw] = rows.map { Raw(id: $0["id"], parent: $0["parentID"], kind: NodeKind(rawValue: $0["kind"]) ?? .bin, name: $0["name"]) }
                guard let lib = raws.first(where: { $0.kind == .library }) else {
                    throw ProjectStoreError.notFound("Library del progetto non trovata.")
                }
                func build(_ r: Raw) -> TreeNode {
                    let kids = raws.filter { $0.parent == r.id }.map(build)
                    let count = r.kind == .bin ? (countByBin[r.id] ?? 0) : kids.reduce(0) { $0 + $1.clipCount }
                    return TreeNode(id: r.id, projectID: projectID, parentID: r.parent, kind: r.kind, name: r.name,
                                    clipCount: count, children: r.kind == .bin ? nil : kids)
                }
                return build(lib)
            }
        }
    }

    // MARK: Giorni e bin

    @discardableResult
    public func createDay(projectID: Int64, name: String) throws -> TreeNode {
        let libraryID: Int64 = try wrap {
            try db.read { db in
                try Int64.fetchOne(db, sql: "SELECT id FROM node WHERE projectID = ? AND kind = 'library'", arguments: [projectID])
            }
        } ?? { throw ProjectStoreError.notFound("Library del progetto non trovata.") }()
        return try createNode(parentID: libraryID, kind: .day, name: name)
    }

    @discardableResult
    public func createBin(dayID: Int64, name: String) throws -> TreeNode {
        try createNode(parentID: dayID, kind: .bin, name: name)
    }

    private func createNode(parentID: Int64, kind: NodeKind, name: String) throws -> TreeNode {
        let name = try NameValidator.validated(name)
        return try wrap {
            try db.write { db in
                guard let parent = try Row.fetchOne(db, sql: "SELECT projectID, kind FROM node WHERE id = ?", arguments: [parentID]) else {
                    throw ProjectStoreError.notFound("Cartella padre non trovata.")
                }
                let parentKind = NodeKind(rawValue: parent["kind"])
                if kind == .day && parentKind != .library || kind == .bin && parentKind != .day {
                    throw ProjectStoreError.invalidOperation(kind == .day
                        ? "Le cartelle giorno si creano dentro la Library."
                        : "I bin si creano dentro una cartella giorno.")
                }
                if try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM node WHERE parentID = ? AND name = ?", arguments: [parentID, name]) ?? 0 > 0 {
                    throw ProjectStoreError.duplicateName("Esiste già «\(name)» in questa cartella.")
                }
                let projectID: Int64 = parent["projectID"]
                try db.execute(sql: "INSERT INTO node(projectID, parentID, kind, name, createdAt) VALUES (?, ?, ?, ?, ?)",
                               arguments: [projectID, parentID, kind.rawValue, name, Date().timeIntervalSince1970])
                return TreeNode(id: db.lastInsertedRowID, projectID: projectID, parentID: parentID, kind: kind,
                                name: name, clipCount: 0, children: kind == .bin ? nil : [])
            }
        }
    }

    /// Rinomina solo nel database: le cartelle già create su disco NON vengono rinominate.
    public func renameNode(id: Int64, to newName: String) throws {
        let name = try NameValidator.validated(newName)
        try wrap {
            try db.write { db in
                guard let row = try Row.fetchOne(db, sql: "SELECT parentID, kind FROM node WHERE id = ?", arguments: [id]) else {
                    throw ProjectStoreError.notFound("Elemento non trovato.")
                }
                if NodeKind(rawValue: row["kind"]) == .library {
                    throw ProjectStoreError.invalidOperation("La Library non si può rinominare.")
                }
                let parent: Int64? = row["parentID"]
                if try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM node WHERE parentID IS ? AND name = ? AND id <> ?", arguments: [parent, name, id]) ?? 0 > 0 {
                    throw ProjectStoreError.duplicateName("Esiste già «\(name)» in questa cartella.")
                }
                try db.execute(sql: "UPDATE node SET name = ? WHERE id = ?", arguments: [name, id])
            }
        }
    }

    public struct DeletionImpact: Equatable {
        public var bins: Int
        public var offloads: Int
        public var clips: Int
    }

    public func deletionImpact(nodeID: Int64) throws -> DeletionImpact {
        try wrap {
            try db.read { db in
                let sub = "WITH RECURSIVE sub(id) AS (SELECT id FROM node WHERE id = ? UNION ALL SELECT n.id FROM node n JOIN sub ON n.parentID = sub.id)"
                let bins = try Int.fetchOne(db, sql: sub + " SELECT COUNT(*) FROM node WHERE id IN (SELECT id FROM sub) AND kind = 'bin'", arguments: [nodeID]) ?? 0
                let offloads = try Int.fetchOne(db, sql: sub + " SELECT COUNT(*) FROM offload WHERE binID IN (SELECT id FROM sub)", arguments: [nodeID]) ?? 0
                let clips = try Int.fetchOne(db, sql: sub + " SELECT COUNT(*) FROM clip WHERE binID IN (SELECT id FROM sub)", arguments: [nodeID]) ?? 0
                return DeletionImpact(bins: bins, offloads: offloads, clips: clips)
            }
        }
    }

    /// Elimina giorno o bin (e il loro contenuto nel database). Non tocca il disco.
    public func deleteNode(id: Int64) throws {
        try wrap {
            try db.write { db in
                guard let kind = try String.fetchOne(db, sql: "SELECT kind FROM node WHERE id = ?", arguments: [id]) else {
                    throw ProjectStoreError.notFound("Elemento non trovato.")
                }
                if NodeKind(rawValue: kind) == .library {
                    throw ProjectStoreError.invalidOperation("La Library non si può eliminare (elimina il progetto).")
                }
                try db.execute(sql: "DELETE FROM node WHERE id = ?", arguments: [id])
            }
        }
    }

    /// Progetto/giorno/bin per costruire il percorso di destinazione di un offload.
    public func binTarget(binID: Int64) throws -> BinTarget? {
        try wrap {
            try db.read { db in
                guard let row = try Row.fetchOne(db, sql: """
                    SELECT b.id AS binID, b.name AS binName, d.name AS dayName, p.id AS projectID, p.name AS projectName
                    FROM node b JOIN node d ON d.id = b.parentID JOIN project p ON p.id = b.projectID
                    WHERE b.id = ? AND b.kind = 'bin' AND d.kind = 'day'
                    """, arguments: [binID]) else { return nil }
                return BinTarget(projectID: row["projectID"], projectName: row["projectName"], dayName: row["dayName"],
                                 binID: row["binID"], binName: row["binName"])
            }
        }
    }

    // MARK: Offload

    /// Registra l'inizio di un offload nel bin (stato "running"). Se `jobID` esiste già (Riprendi) lo riporta a "running".
    public func beginOffload(jobID: UUID, binID: Int64, sourcePath: String, destinations: [String], startedAt: Date = Date()) throws {
        try wrap {
            try db.write { db in
                try db.execute(sql: """
                    INSERT INTO offload(jobID, binID, sourcePath, destinationsJSON, startedAt, outcome)
                    VALUES (?, ?, ?, ?, ?, 'running')
                    ON CONFLICT(jobID) DO UPDATE SET outcome = 'running', finishedAt = NULL
                    """, arguments: [jobID.uuidString, binID, sourcePath, ProjectStore.json(destinations), startedAt.timeIntervalSince1970])
            }
        }
    }

    /// Registra il risultato: aggiorna l'offload e inserisce/aggiorna le clip (i metadata già letti si conservano).
    /// Se i controlli preliminari sono falliti l'offload non è mai partito e il record viene rimosso.
    public func finishOffload(_ result: OffloadResult, finishedAt: Date = Date()) throws {
        try wrap {
            try db.write { db in
                guard let offloadID = try Int64.fetchOne(db, sql: "SELECT id FROM offload WHERE jobID = ?", arguments: [result.job.id.uuidString]),
                      let binID = try Int64.fetchOne(db, sql: "SELECT binID FROM offload WHERE id = ?", arguments: [offloadID]) else { return }
                if result.outcome == .preflightFailed {
                    try db.execute(sql: "DELETE FROM offload WHERE id = ? AND NOT EXISTS (SELECT 1 FROM clip WHERE offloadID = ?)", arguments: [offloadID, offloadID])
                    return
                }
                let total = result.files.reduce(Int64(0)) { $0 + $1.size }
                try db.execute(sql: "UPDATE offload SET outcome = ?, finishedAt = ?, allOK = ?, totalBytes = ? WHERE id = ?",
                               arguments: [result.outcome.rawValue, finishedAt.timeIntervalSince1970, result.allOK ? 1 : 0, total, offloadID])
                for f in result.files {
                    let statuses = f.destinations.map { $0.status }
                    let aggregate: String
                    if statuses.contains(.mismatch) { aggregate = "mismatch" }
                    else if statuses.contains(.error) { aggregate = "error" }
                    else if !statuses.isEmpty && statuses.allSatisfy({ $0 == .ok }) { aggregate = "ok" }
                    else { aggregate = "pending" }
                    try db.execute(sql: """
                        INSERT INTO clip(offloadID, binID, relativePath, name, size, sourceHash, status, destStatusJSON, isMedia)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(offloadID, relativePath) DO UPDATE SET
                          size = excluded.size, sourceHash = excluded.sourceHash,
                          status = excluded.status, destStatusJSON = excluded.destStatusJSON
                        """, arguments: [offloadID, binID, f.relativePath, (f.relativePath as NSString).lastPathComponent, f.size,
                                         f.sourceHash, aggregate, ProjectStore.json(statuses.map { $0.rawValue }),
                                         MediaClassifier.isMedia(relativePath: f.relativePath) ? 1 : 0])
                }
            }
        }
    }

    public func offloadRecord(jobID: UUID) throws -> OffloadRecord? {
        try wrap { try db.read { db in try Row.fetchOne(db, sql: "SELECT * FROM offload WHERE jobID = ?", arguments: [jobID.uuidString]).map(ProjectStore.offload) } }
    }

    public func offloads(binID: Int64) throws -> [OffloadRecord] {
        try wrap {
            try db.read { db in
                try Row.fetchAll(db, sql: "SELECT * FROM offload WHERE binID = ? ORDER BY startedAt", arguments: [binID]).map(ProjectStore.offload)
            }
        }
    }

    private static func offload(_ r: Row) -> OffloadRecord {
        OffloadRecord(id: r["id"], jobID: UUID(uuidString: r["jobID"]) ?? UUID(), binID: r["binID"], sourcePath: r["sourcePath"],
                      destinations: decode([String].self, r["destinationsJSON"], default: []),
                      startedAt: date(r["startedAt"]), finishedAt: (r["finishedAt"] as Double?).map(date),
                      outcome: r["outcome"], allOK: (r["allOK"] as Int) == 1, totalBytes: r["totalBytes"])
    }

    // MARK: Clip

    /// Clip del nodo scelto (progetto → tutte, giorno → quelle dei suoi bin, bin → le sue).
    public func clips(underNode nodeID: Int64, mediaOnly: Bool = true) throws -> [ClipRecord] {
        try wrap {
            try db.read { db in
                try Row.fetchAll(db, sql: """
                    WITH RECURSIVE sub(id) AS (SELECT id FROM node WHERE id = ? UNION ALL SELECT n.id FROM node n JOIN sub ON n.parentID = sub.id)
                    SELECT c.*, o.startedAt AS offloadDate, b.name AS binName, COALESCE(d.name, '') AS dayName
                    FROM clip c JOIN offload o ON o.id = c.offloadID JOIN node b ON b.id = c.binID LEFT JOIN node d ON d.id = b.parentID
                    WHERE c.binID IN (SELECT id FROM sub) AND (? = 0 OR c.isMedia = 1)
                    ORDER BY dayName COLLATE NOCASE, binName COLLATE NOCASE, c.relativePath COLLATE NOCASE
                    """, arguments: [nodeID, mediaOnly ? 1 : 0]).map {
                    ClipRecord(id: $0["id"], offloadID: $0["offloadID"], binID: $0["binID"], relativePath: $0["relativePath"],
                               name: $0["name"], size: $0["size"], sourceHash: $0["sourceHash"], status: $0["status"],
                               destinationStatuses: ProjectStore.decode([String].self, $0["destStatusJSON"], default: []),
                               isMedia: ($0["isMedia"] as Int) == 1,
                               metadata: ProjectStore.decode([String: String].self, $0["metadataJSON"], default: [:]),
                               offloadDate: ProjectStore.date($0["offloadDate"]), binName: $0["binName"], dayName: $0["dayName"])
                }
            }
        }
    }

    /// Unisce i valori ai metadata della clip (fase metadata). Le chiavi assenti restano "N/D" nell'interfaccia.
    public func updateMetadata(clipID: Int64, merging values: [String: String]) throws {
        try wrap {
            try db.write { db in
                guard let text = try String.fetchOne(db, sql: "SELECT metadataJSON FROM clip WHERE id = ?", arguments: [clipID]) else {
                    throw ProjectStoreError.notFound("Clip non trovata.")
                }
                var current = ProjectStore.decode([String: String].self, text, default: [:])
                for (k, v) in values { current[k] = v }
                try db.execute(sql: "UPDATE clip SET metadataJSON = ? WHERE id = ?", arguments: [ProjectStore.json(current), clipID])
            }
        }
    }
}
