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
        m.registerMigration("v2-history") { db in
            try db.execute(sql: """
                CREATE TABLE event (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    projectID INTEGER NOT NULL REFERENCES project(id) ON DELETE CASCADE,
                    at REAL NOT NULL,
                    kind TEXT NOT NULL,
                    title TEXT NOT NULL,
                    detail TEXT
                );
                CREATE INDEX event_project ON event(projectID, at);
                """)
        }
        m.registerMigration("v3-history-only-completed-offloads") { db in
            // Scelta dell'utente: la cronologia mostra solo gli offload completati.
            try db.execute(sql: "DELETE FROM event WHERE kind <> 'offloadCompleted'")
        }
        m.registerMigration("v4-clip-modified-date") { db in
            try db.execute(sql: "ALTER TABLE clip ADD COLUMN modifiedAt REAL")
        }
        m.registerMigration("v5-event-texts") { db in
            // Testi della cronologia in forma traducibile (chiave + parametri): così seguono la lingua scelta dall'utente.
            try db.execute(sql: "ALTER TABLE event ADD COLUMN i18n TEXT")
        }
        return m
    }

    // MARK: Utilità

    private func wrap<T>(_ body: () throws -> T) throws -> T {
        do { return try body() }
        catch let e as ProjectStoreError { throw e }
        catch { throw ProjectStoreError.database("\(error)") }
    }

    /// Tipi di voce registrati nella cronologia. Per scelta dell'utente: SOLO gli offload completati con tutti i file OK.
    /// Per registrare altro (es. rinomine, problemi, annullamenti) basta aggiungere il tipo qui.
    public static let recordedEventKinds: Set<String> = ["offloadCompleted"]

    /// `titleText`/`detailText` (se presenti) si salvano come chiave + parametri e vengono ricomposti nella lingua corrente
    /// a ogni lettura; `title`/`detail` restano come testo di ripiego (voci vecchie o senza traduzione).
    private static func log(_ db: Database, projectID: Int64, kind: String, title: String, detail: String? = nil,
                            titleText: LocText? = nil, detailText: LocText? = nil) throws {
        guard recordedEventKinds.contains(kind) else { return }
        let texts = titleText.map { EventTexts(title: $0, detail: detailText) }
        try db.execute(sql: "INSERT INTO event(projectID, at, kind, title, detail, i18n) VALUES (?, ?, ?, ?, ?, ?)",
                       arguments: [projectID, Date().timeIntervalSince1970, kind, title, detail, texts.map { json($0) }])
    }

    private static func projectID(ofNode id: Int64, _ db: Database) throws -> Int64? {
        try Int64.fetchOne(db, sql: "SELECT projectID FROM node WHERE id = ?", arguments: [id])
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
                    throw ProjectStoreError.duplicateName(tr("Esiste già un progetto chiamato «{0}».", name))
                }
                try db.execute(sql: "INSERT INTO project(name, createdAt) VALUES (?, ?)",
                               arguments: [name, createdAt.timeIntervalSince1970])
                let id = db.lastInsertedRowID
                try db.execute(sql: "INSERT INTO node(projectID, parentID, kind, name, createdAt) VALUES (?, NULL, 'library', 'Library', ?)",
                               arguments: [id, createdAt.timeIntervalSince1970])
                try ProjectStore.log(db, projectID: id, kind: "projectCreated", title: "Progetto «\(name)» creato")
                return Project(id: id, name: name, createdAt: createdAt)
            }
        }
    }

    public func renameProject(id: Int64, to newName: String) throws {
        let name = try NameValidator.validated(newName)
        try wrap {
            try db.write { db in
                if try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM project WHERE name = ? AND id <> ?", arguments: [name, id]) ?? 0 > 0 {
                    throw ProjectStoreError.duplicateName(tr("Esiste già un progetto chiamato «{0}».", name))
                }
                guard let old = try String.fetchOne(db, sql: "SELECT name FROM project WHERE id = ?", arguments: [id]) else {
                    throw ProjectStoreError.notFound(tr("Progetto non trovato."))
                }
                try db.execute(sql: "UPDATE project SET name = ? WHERE id = ?", arguments: [name, id])
                if old != name {
                    try ProjectStore.log(db, projectID: id, kind: "projectRenamed", title: "Progetto rinominato: «\(old)» → «\(name)»")
                }
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
                    throw ProjectStoreError.notFound(tr("Library del progetto non trovata."))
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
        } ?? { throw ProjectStoreError.notFound(tr("Library del progetto non trovata.")) }()
        return try createNode(parentID: libraryID, kind: .day, name: name)
    }

    /// Sottocartella facoltativa per ordinare il progetto: si crea nella Library, in un giorno o in un'altra sottocartella.
    @discardableResult
    public func createFolder(parentID: Int64, name: String) throws -> TreeNode {
        try createNode(parentID: parentID, kind: .folder, name: name)
    }

    /// Bin: si crea nella Library, in un giorno o in una sottocartella.
    @discardableResult
    public func createBin(parentID: Int64, name: String) throws -> TreeNode {
        try createNode(parentID: parentID, kind: .bin, name: name)
    }

    /// Bin con questo nome (senza distinzione tra maiuscole e minuscole, come sul disco) nella cartella; se non c'è lo crea.
    public func findOrCreateBin(parentID: Int64, name: String) throws -> (node: TreeNode, created: Bool) {
        let name = try NameValidator.validated(name)
        let existing: TreeNode? = try wrap {
            try db.read { db in
                try Row.fetchOne(db, sql: """
                    SELECT n.id, n.projectID, n.name, (SELECT COUNT(*) FROM clip c WHERE c.binID = n.id AND c.isMedia = 1 AND c.status = 'ok') AS n_clips
                    FROM node n WHERE n.parentID = ? AND n.kind = 'bin' AND n.name = ? COLLATE NOCASE
                    """, arguments: [parentID, name]).map {
                    TreeNode(id: $0["id"], projectID: $0["projectID"], parentID: parentID, kind: .bin, name: $0["name"],
                             clipCount: $0["n_clips"], children: nil)
                }
            }
        }
        if let existing { return (existing, false) }
        return (try createBin(parentID: parentID, name: name), true)
    }

    private func createNode(parentID: Int64, kind: NodeKind, name: String) throws -> TreeNode {
        let name = try NameValidator.validated(name)
        return try wrap {
            try db.write { db in
                guard let parent = try Row.fetchOne(db, sql: "SELECT projectID, kind FROM node WHERE id = ?", arguments: [parentID]) else {
                    throw ProjectStoreError.notFound(tr("Cartella padre non trovata."))
                }
                let parentKind = NodeKind(rawValue: parent["kind"])
                switch kind {
                case .day where parentKind != .library:
                    throw ProjectStoreError.invalidOperation(tr("Le cartelle giorno si creano dentro la Library."))
                case .folder where parentKind == .bin, .bin where parentKind == .bin:
                    throw ProjectStoreError.invalidOperation(tr("Dentro un bin non si possono creare cartelle o altri bin."))
                case .library:
                    throw ProjectStoreError.invalidOperation(tr("La Library esiste già."))
                default: break
                }
                if try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM node WHERE parentID = ? AND name = ?", arguments: [parentID, name]) ?? 0 > 0 {
                    throw ProjectStoreError.duplicateName(tr("Esiste già «{0}» in questa cartella.", name))
                }
                let projectID: Int64 = parent["projectID"]
                try db.execute(sql: "INSERT INTO node(projectID, parentID, kind, name, createdAt) VALUES (?, ?, ?, ?, ?)",
                               arguments: [projectID, parentID, kind.rawValue, name, Date().timeIntervalSince1970])
                let parentName = try String.fetchOne(db, sql: "SELECT name FROM node WHERE id = ?", arguments: [parentID]) ?? ""
                switch kind {
                case .day: try ProjectStore.log(db, projectID: projectID, kind: "dayCreated", title: "Cartella giorno «\(name)» creata")
                case .folder: try ProjectStore.log(db, projectID: projectID, kind: "folderCreated", title: "Cartella «\(name)» creata in «\(parentName)»")
                default: try ProjectStore.log(db, projectID: projectID, kind: "binCreated", title: "Bin «\(name)» creato in «\(parentName)»")
                }
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
                    throw ProjectStoreError.notFound(tr("Elemento non trovato."))
                }
                if NodeKind(rawValue: row["kind"]) == .library {
                    throw ProjectStoreError.invalidOperation(tr("La Library non si può rinominare."))
                }
                let parent: Int64? = row["parentID"]
                if try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM node WHERE parentID IS ? AND name = ? AND id <> ?", arguments: [parent, name, id]) ?? 0 > 0 {
                    throw ProjectStoreError.duplicateName(tr("Esiste già «{0}» in questa cartella.", name))
                }
                let old = try String.fetchOne(db, sql: "SELECT name FROM node WHERE id = ?", arguments: [id]) ?? ""
                try db.execute(sql: "UPDATE node SET name = ? WHERE id = ?", arguments: [name, id])
                if old != name, let pid = try ProjectStore.projectID(ofNode: id, db) {
                    let what = ["day": "Cartella giorno", "folder": "Cartella"][row["kind"] as String] ?? "Bin"
                    try ProjectStore.log(db, projectID: pid, kind: "nodeRenamed", title: "\(what) rinominato: «\(old)» → «\(name)»",
                                         detail: "Rinominato solo nel programma: le cartelle già create sui dischi non sono state rinominate.")
                }
            }
        }
    }

    /// Sposta un giorno, una cartella o un bin dentro un'altra cartella (o nella Library) dello stesso progetto.
    /// Cambia solo l'albero del programma: clip, offload e file sui dischi restano dove sono.
    public func moveNode(id: Int64, toParentID newParentID: Int64) throws {
        try wrap {
            try db.write { db in
                guard let node = try Row.fetchOne(db, sql: "SELECT projectID, parentID, kind, name FROM node WHERE id = ?", arguments: [id]) else {
                    throw ProjectStoreError.notFound(tr("Elemento non trovato."))
                }
                guard let target = try Row.fetchOne(db, sql: "SELECT projectID, kind, name FROM node WHERE id = ?", arguments: [newParentID]) else {
                    throw ProjectStoreError.notFound(tr("Cartella di destinazione non trovata."))
                }
                let kind = NodeKind(rawValue: node["kind"]), targetKind = NodeKind(rawValue: target["kind"])
                let name: String = node["name"], targetName: String = target["name"]
                if kind == .library { throw ProjectStoreError.invalidOperation(tr("La Library non si può spostare.")) }
                if (node["projectID"] as Int64) != (target["projectID"] as Int64) {
                    throw ProjectStoreError.invalidOperation(tr("Non si può spostare un elemento in un altro progetto."))
                }
                if targetKind == .bin { throw ProjectStoreError.invalidOperation(tr("Dentro un bin non si può spostare nulla.")) }
                if kind == .day && targetKind != .library {
                    throw ProjectStoreError.invalidOperation(tr("Le cartelle giorno stanno solo nella Library."))
                }
                if (node["parentID"] as Int64?) == newParentID { return }
                let inside = try Int.fetchOne(db, sql: """
                    WITH RECURSIVE sub(id) AS (SELECT id FROM node WHERE id = ? UNION ALL SELECT n.id FROM node n JOIN sub ON n.parentID = sub.id)
                    SELECT COUNT(*) FROM sub WHERE id = ?
                    """, arguments: [id, newParentID]) ?? 0
                if inside > 0 { throw ProjectStoreError.invalidOperation(tr("Non si può spostare una cartella dentro se stessa.")) }
                if try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM node WHERE parentID = ? AND name = ?", arguments: [newParentID, name]) ?? 0 > 0 {
                    throw ProjectStoreError.duplicateName(tr("In «{0}» esiste già «{1}».", targetName, name))
                }
                let fromName: String = try (node["parentID"] as Int64?).flatMap {
                    try String.fetchOne(db, sql: "SELECT name FROM node WHERE id = ?", arguments: [$0])
                } ?? ""
                try db.execute(sql: "UPDATE node SET parentID = ? WHERE id = ?", arguments: [newParentID, id])
                try ProjectStore.log(db, projectID: node["projectID"], kind: "nodeMoved", title: "«\(name)» spostato da «\(fromName)» a «\(targetName)»")
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
                    throw ProjectStoreError.notFound(tr("Elemento non trovato."))
                }
                if NodeKind(rawValue: kind) == .library {
                    throw ProjectStoreError.invalidOperation(tr("La Library non si può eliminare (elimina il progetto)."))
                }
                let name = try String.fetchOne(db, sql: "SELECT name FROM node WHERE id = ?", arguments: [id]) ?? ""
                let pid = try ProjectStore.projectID(ofNode: id, db)
                let sub = "WITH RECURSIVE sub(id) AS (SELECT id FROM node WHERE id = ? UNION ALL SELECT n.id FROM node n JOIN sub ON n.parentID = sub.id)"
                let bins = try Int.fetchOne(db, sql: sub + " SELECT COUNT(*) FROM node WHERE id IN (SELECT id FROM sub) AND kind = 'bin'", arguments: [id]) ?? 0
                let offloads = try Int.fetchOne(db, sql: sub + " SELECT COUNT(*) FROM offload WHERE binID IN (SELECT id FROM sub)", arguments: [id]) ?? 0
                let clips = try Int.fetchOne(db, sql: sub + " SELECT COUNT(*) FROM clip WHERE binID IN (SELECT id FROM sub)", arguments: [id]) ?? 0
                try db.execute(sql: "DELETE FROM node WHERE id = ?", arguments: [id])
                if let pid {
                    let what = NodeKind(rawValue: kind) == .day ? "Cartella giorno «\(name)» eliminata" : NodeKind(rawValue: kind) == .folder ? "Cartella «\(name)» eliminata" : "Bin «\(name)» eliminato"
                    try ProjectStore.log(db, projectID: pid, kind: "nodeDeleted", title: what,
                                         detail: "Eliminati dal programma: \(bins) bin, \(offloads) offload, \(clips) file registrati. I file sui dischi non sono stati toccati.")
                }
            }
        }
    }

    /// Progetto e cartelle di un bin, per costruire il percorso di destinazione di un offload.
    public func binTarget(binID: Int64) throws -> BinTarget? {
        try wrap {
            try db.read { db in
                guard let row = try Row.fetchOne(db, sql: """
                    SELECT b.id AS binID, b.name AS binName, b.parentID AS parentID, p.id AS projectID, p.name AS projectName
                    FROM node b JOIN project p ON p.id = b.projectID WHERE b.id = ? AND b.kind = 'bin'
                    """, arguments: [binID]) else { return nil }
                var path: [String] = []
                var cursor: Int64? = row["parentID"]
                while let id = cursor, let n = try Row.fetchOne(db, sql: "SELECT name, kind, parentID FROM node WHERE id = ?", arguments: [id]) {
                    if NodeKind(rawValue: n["kind"]) != .library { path.insert(n["name"], at: 0) }
                    cursor = n["parentID"]
                }
                return BinTarget(projectID: row["projectID"], projectName: row["projectName"], folderPath: path,
                                 binID: row["binID"], binName: row["binName"])
            }
        }
    }

    // MARK: Offload

    /// Registra l'inizio di un offload nel bin (stato "running"). Se `jobID` esiste già (Riprendi) lo riporta a "running".
    public func beginOffload(jobID: UUID, binID: Int64, sourcePath: String, destinations: [String], startedAt: Date = Date()) throws {
        try wrap {
            try db.write { db in
                let existed = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM offload WHERE jobID = ?", arguments: [jobID.uuidString]) ?? 0 > 0
                try db.execute(sql: """
                    INSERT INTO offload(jobID, binID, sourcePath, destinationsJSON, startedAt, outcome)
                    VALUES (?, ?, ?, ?, ?, 'running')
                    ON CONFLICT(jobID) DO UPDATE SET outcome = 'running', finishedAt = NULL
                    """, arguments: [jobID.uuidString, binID, sourcePath, ProjectStore.json(destinations), startedAt.timeIntervalSince1970])
                if let pid = try ProjectStore.projectID(ofNode: binID, db) {
                    let binName = try String.fetchOne(db, sql: "SELECT name FROM node WHERE id = ?", arguments: [binID]) ?? ""
                    try ProjectStore.log(db, projectID: pid, kind: existed ? "offloadResumed" : "offloadStarted",
                                         title: existed ? "Offload ripreso nel bin «\(binName)»" : "Offload avviato nel bin «\(binName)»",
                                         detail: "Sorgente: \(sourcePath)\n" + destinations.enumerated().map { "Destinazione \($0.offset + 1): \($0.element)" }.joined(separator: "\n"))
                }
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
                let pid = try ProjectStore.projectID(ofNode: binID, db)
                let binName = try String.fetchOne(db, sql: "SELECT name FROM node WHERE id = ?", arguments: [binID]) ?? ""
                if result.outcome == .preflightFailed {
                    try db.execute(sql: "DELETE FROM offload WHERE id = ? AND NOT EXISTS (SELECT 1 FROM clip WHERE offloadID = ?)", arguments: [offloadID, offloadID])
                    if let pid {
                        try ProjectStore.log(db, projectID: pid, kind: "offloadNotStarted",
                                             title: "Offload NON avviato nel bin «\(binName)»: controlli preliminari falliti",
                                             detail: result.preflightErrors.joined(separator: "\n"))
                    }
                    return
                }
                let total = result.files.reduce(Int64(0)) { $0 + $1.size }
                try db.execute(sql: "UPDATE offload SET outcome = ?, finishedAt = ?, allOK = ?, totalBytes = ? WHERE id = ?",
                               arguments: [result.outcome.rawValue, finishedAt.timeIntervalSince1970, result.allOK ? 1 : 0, total, offloadID])
                if let pid {
                    let nDest = result.job.destinationRoots.count
                    let mismatches = result.files.reduce(0) { $0 + $1.destinations.filter { $0.status == .mismatch }.count }
                    let errors = result.files.reduce(0) { $0 + $1.destinations.filter { $0.status == .error }.count }
                    let okFiles = result.files.filter { $0.destinations.allSatisfy { $0.status == .ok } }.count
                    let duration = Format.duration(result.elapsed)
                    switch result.outcome {
                    case .cancelled:
                        try ProjectStore.log(db, projectID: pid, kind: "offloadCancelled",
                                             title: "Offload annullato nel bin «\(binName)»",
                                             detail: "File parziali rimossi dalle destinazioni. \(okFiles) file su \(result.files.count) già verificati OK restano. Durata \(duration). «Riprendi» continua da dove si è fermato.")
                    case .completed where result.allOK:
                        let title = LocText("Offload completato nel bin «{0}»: {1} file, {2}, tutti OK", binName, result.files.count, Format.bytes(total))
                        let detail = result.skippedAlreadyVerified > 0
                            ? LocText("Riletti dal disco con XXH64 identico alla sorgente su {0} destinazione/i. Durata {1}. {2} file già verificati in precedenza.", nDest, duration, result.skippedAlreadyVerified)
                            : LocText("Riletti dal disco con XXH64 identico alla sorgente su {0} destinazione/i. Durata {1}.", nDest, duration)
                        try ProjectStore.log(db, projectID: pid, kind: "offloadCompleted", title: title.text, detail: detail.text,
                                             titleText: title, detailText: detail)
                    default:
                        var lines: [String] = []
                        for f in result.files {
                            for (d, r) in f.destinations.enumerated() where r.status != .ok {
                                lines.append("\(f.relativePath) — destinazione \(d + 1): \(r.status.label)\(r.message.map { ": \($0)" } ?? "")")
                            }
                        }
                        let shown = lines.prefix(8).joined(separator: "\n") + (lines.count > 8 ? "\n… e altri \(lines.count - 8)" : "")
                        let dead: [String] = result.destinationErrors.enumerated().compactMap { (index, message) in
                            message.map { "Destinazione \(index + 1) interrotta: \($0)" }
                        }
                        try ProjectStore.log(db, projectID: pid, kind: "offloadProblems",
                                             title: "Offload terminato con PROBLEMI nel bin «\(binName)»: \(mismatches) MISMATCH, \(errors) ERRORI",
                                             detail: (dead + [shown]).filter { !$0.isEmpty }.joined(separator: "\n"))
                    }
                }
                for f in result.files {
                    let statuses = f.destinations.map { $0.status }
                    let aggregate: String
                    if statuses.contains(.mismatch) { aggregate = "mismatch" }
                    else if statuses.contains(.error) { aggregate = "error" }
                    else if !statuses.isEmpty && statuses.allSatisfy({ $0 == .ok }) { aggregate = "ok" }
                    else { aggregate = "pending" }
                    try db.execute(sql: """
                        INSERT INTO clip(offloadID, binID, relativePath, name, size, sourceHash, status, destStatusJSON, isMedia, modifiedAt)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(offloadID, relativePath) DO UPDATE SET
                          size = excluded.size, sourceHash = excluded.sourceHash,
                          status = excluded.status, destStatusJSON = excluded.destStatusJSON,
                          modifiedAt = COALESCE(excluded.modifiedAt, clip.modifiedAt)
                        """, arguments: [offloadID, binID, f.relativePath, (f.relativePath as NSString).lastPathComponent, f.size,
                                         f.sourceHash, aggregate, ProjectStore.json(statuses.map { $0.rawValue }),
                                         MediaClassifier.isMedia(relativePath: f.relativePath) ? 1 : 0,
                                         f.modificationDate?.timeIntervalSince1970])
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
                    SELECT c.*, o.startedAt AS offloadDate, b.name AS binName, CASE WHEN d.kind = 'library' THEN '' ELSE COALESCE(d.name, '') END AS dayName
                    FROM clip c JOIN offload o ON o.id = c.offloadID JOIN node b ON b.id = c.binID LEFT JOIN node d ON d.id = b.parentID
                    WHERE c.binID IN (SELECT id FROM sub) AND (? = 0 OR c.isMedia = 1)
                    ORDER BY dayName COLLATE NOCASE, binName COLLATE NOCASE, c.relativePath COLLATE NOCASE
                    """, arguments: [nodeID, mediaOnly ? 1 : 0]).map {
                    ClipRecord(id: $0["id"], offloadID: $0["offloadID"], binID: $0["binID"], relativePath: $0["relativePath"],
                               name: $0["name"], size: $0["size"], sourceHash: $0["sourceHash"], status: $0["status"],
                               destinationStatuses: ProjectStore.decode([String].self, $0["destStatusJSON"], default: []),
                               isMedia: ($0["isMedia"] as Int) == 1,
                               metadata: ProjectStore.decode([String: String].self, $0["metadataJSON"], default: [:]),
                               offloadDate: ProjectStore.date($0["offloadDate"]), binName: $0["binName"], dayName: $0["dayName"],
                               modifiedAt: ($0["modifiedAt"] as Double?).map(ProjectStore.date))
                }
            }
        }
    }

    /// Unisce i valori ai metadata della clip (fase metadata). Le chiavi assenti restano "N/D" nell'interfaccia.
    public func updateMetadata(clipID: Int64, merging values: [String: String]) throws {
        try wrap {
            try db.write { db in
                guard let text = try String.fetchOne(db, sql: "SELECT metadataJSON FROM clip WHERE id = ?", arguments: [clipID]) else {
                    throw ProjectStoreError.notFound(tr("Clip non trovata."))
                }
                var current = ProjectStore.decode([String: String].self, text, default: [:])
                for (k, v) in values { current[k] = v }
                try db.execute(sql: "UPDATE clip SET metadataJSON = ? WHERE id = ?", arguments: [ProjectStore.json(current), clipID])
            }
        }
    }

    // MARK: Cronologia

    /// Aggiunge una voce di cronologia legata a un offload (es. fine della fase di copia).
    public func logOffloadEvent(jobID: UUID, kind: String, title: String, detail: String? = nil) throws {
        try wrap {
            try db.write { db in
                guard let binID = try Int64.fetchOne(db, sql: "SELECT binID FROM offload WHERE jobID = ?", arguments: [jobID.uuidString]),
                      let pid = try ProjectStore.projectID(ofNode: binID, db) else { return }
                try ProjectStore.log(db, projectID: pid, kind: kind, title: title, detail: detail)
            }
        }
    }

    /// Aggiunge una voce libera alla cronologia del progetto (usata anche dalle fasi successive: metadata, report).
    public func logEvent(projectID: Int64, kind: String, title: String, detail: String? = nil) throws {
        try wrap { try db.write { db in try ProjectStore.log(db, projectID: projectID, kind: kind, title: title, detail: detail) } }
    }

    /// Cancella la cronologia del progetto (solo le voci di cronologia: clip, offload e file sui dischi non vengono toccati).
    /// Restituisce quante voci sono state cancellate.
    @discardableResult
    public func clearHistory(projectID: Int64) throws -> Int {
        try wrap {
            try db.write { db in
                try db.execute(sql: "DELETE FROM event WHERE projectID = ?", arguments: [projectID])
                return db.changesCount
            }
        }
    }

    /// Cronologia del progetto, dalla più recente.
    public func history(projectID: Int64, limit: Int = 500) throws -> [HistoryEvent] {
        try wrap {
            try db.read { db in
                try Row.fetchAll(db, sql: "SELECT * FROM event WHERE projectID = ? ORDER BY at DESC, id DESC LIMIT ?",
                                 arguments: [projectID, limit]).map { row in
                    let raw: String? = row["i18n"]
                    let texts: EventTexts? = raw.flatMap { ProjectStore.decode(EventTexts?.self, $0, default: nil) }
                    let storedDetail: String? = row["detail"]
                    return HistoryEvent(id: row["id"], projectID: row["projectID"], date: ProjectStore.date(row["at"]),
                                        kind: row["kind"], title: texts?.title.text ?? row["title"],
                                        detail: texts != nil ? texts?.detail?.text : storedDetail)
                }
            }
        }
    }

    /// Cartelle di destinazione dell'offload (nell'ordine delle destinazioni).
    public func destinationRoots(offloadID: Int64) throws -> [String] {
        try wrap {
            try db.read { db in
                let text = try String.fetchOne(db, sql: "SELECT destinationsJSON FROM offload WHERE id = ?", arguments: [offloadID]) ?? "[]"
                return ProjectStore.decode([String].self, text, default: [])
            }
        }
    }

    /// Clip registrate per un offload (per leggere i metadata subito dopo la copia).
    public func clips(forJobID jobID: UUID) throws -> [ClipRecord] {
        guard let record = try offloadRecord(jobID: jobID) else { return [] }
        return try clips(underNode: record.binID, mediaOnly: true).filter { $0.offloadID == record.id }
    }

    /// Riepilogo di quanto è stato scaricato sotto il nodo (giorno, cartella, Library o bin).
    public func recap(underNode nodeID: Int64) throws -> ProjectRecap {
        ProjectRecap.make(clips: try clips(underNode: nodeID, mediaOnly: false), offloads: try offloads(underNode: nodeID))
    }

    /// Offload registrati nei bin sotto il nodo (progetto → tutti, giorno → i suoi bin, bin → i suoi), in ordine di tempo.
    public func offloads(underNode nodeID: Int64) throws -> [OffloadRecord] {
        try wrap {
            try db.read { db in
                try Row.fetchAll(db, sql: """
                    WITH RECURSIVE sub(id) AS (SELECT id FROM node WHERE id = ? UNION ALL SELECT n.id FROM node n JOIN sub ON n.parentID = sub.id)
                    SELECT * FROM offload WHERE binID IN (SELECT id FROM sub) ORDER BY startedAt, id
                    """, arguments: [nodeID]).map(ProjectStore.offload)
            }
        }
    }
}
