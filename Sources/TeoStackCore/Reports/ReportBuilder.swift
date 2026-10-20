import Foundation

/// Costruisce il documento del report (template "Classic") dai dati del database.
/// Nessun valore viene inventato: dati assenti → "N/D"; i totali parziali sono indicati come tali.
public enum ReportBuilder {
    static let nd = ClipColumns.notAvailable

    public static func build(store: ProjectStore, projectID: Int64, nodeID: Int64, options: ReportOptions) throws -> ReportDocument {
        let tree = try store.tree(projectID: projectID)
        guard let scope = find(nodeID, in: tree) else { throw ProjectStoreError.notFound("Elemento del progetto non trovato.") }

        let allFiles = try store.clips(underNode: nodeID, mediaOnly: false)
        let media = allFiles.filter { $0.isMedia }
        let offloads = try store.offloads(underNode: nodeID)

        var blocks: [ReportBlock] = []
        for section in ReportSection.allCases where options.sections.contains(section) {
            switch section {
            case .shootingDay: blocks.append(shootingDay(tree: tree, scope: scope, files: allFiles))
            case .clips: blocks.append(clipsBlock(media, columnIDs: options.clipColumnIDs))
            case .volume: blocks += volumeBlocks(files: allFiles, offloads: offloads)
            case .productionInfo: blocks.append(productionInfo(options: options, media: media))
            case .clipsOverview: blocks.append(clipsOverview(files: allFiles, media: media, offloads: offloads, tree: tree, scope: scope))
            case .cameraSummary: blocks.append(cameraSummary(media))
            case .videoFormats: blocks.append(videoFormats(media))
            case .notes:
                let text = options.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { blocks.append(ReportBlock(section: .notes, title: "Note", content: .text(text))) }
            }
        }

        let operatorName = options.operatorName.trimmingCharacters(in: .whitespaces)
        return ReportDocument(
            title: "Report",
            template: "Classic",
            meta: [
                ("Progetto", options.projectName),
                ("Operatore", operatorName.isEmpty ? nd : operatorName),
                ("Ambito", scopeTitle(scope: scope, tree: tree)),
                ("Generato il", dateTime(options.generatedAt)),
            ],
            blocks: blocks)
    }

    // MARK: Ambito

    static func find(_ id: Int64, in node: TreeNode) -> TreeNode? {
        if node.id == id { return node }
        for c in node.children ?? [] { if let f = find(id, in: c) { return f } }
        return nil
    }

    public static func scopeTitle(scope: TreeNode, tree: TreeNode) -> String {
        switch scope.kind {
        case .library: return "Progetto completo"
        case .day: return "Giorno \(scope.name)"
        case .bin:
            let day = (tree.children ?? []).first { $0.id == scope.parentID }
            return "Bin \(scope.name)" + (day.map { " (giorno \($0.name))" } ?? "")
        }
    }

    // MARK: Formattazione

    static func dateTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "dd/MM/yyyy HH:mm"
        return f.string(from: d)
    }

    static func seconds(_ clip: ClipRecord) -> Double? {
        clip.metadata["durationSeconds"].flatMap(Double.init)
    }

    /// HH:MM:SS (le durate dei singoli clip sono mostrate con i frame nella tabella Clips).
    static func hms(_ total: Double) -> String {
        let s = Int(total.rounded())
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    /// Durata totale: "N/D" se nessun clip ha la durata, indicata come parziale se mancano alcuni clip.
    static func totalDuration(_ clips: [ClipRecord]) -> ReportCell {
        let known = clips.compactMap(seconds)
        if known.isEmpty { return ReportCell(nd) }
        let total = known.reduce(0, +)
        let text = hms(total) + (known.count < clips.count ? " (parziale: \(known.count)/\(clips.count) clip)" : "")
        return ReportCell(text, raw: String(format: "%.3f", total))
    }

    static func sizeCell(_ bytes: Int64) -> ReportCell { ReportCell(Format.bytes(bytes), raw: String(bytes)) }

    static func distinct(_ values: [String]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for v in values where !v.isEmpty && seen.insert(v).inserted { out.append(v) }
        return out
    }

    static func joined(_ values: [String]) -> String {
        let d = distinct(values)
        return d.isEmpty ? nd : d.joined(separator: "; ")
    }

    static func formatText(_ c: ClipRecord) -> String? {
        let parts = [c.metadata["codec"], c.metadata["resolution"], c.metadata["frameRate"].map { "\($0) fps" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: Shooting Day

    static func shootingDay(tree: TreeNode, scope: TreeNode, files: [ClipRecord]) -> ReportBlock {
        let days = tree.children ?? []
        let dayNames: [String]
        switch scope.kind {
        case .library: dayNames = days.map(\.name)
        case .day: dayNames = [scope.name]
        case .bin: dayNames = days.filter { $0.id == scope.parentID }.map(\.name)
        }
        let columns = [
            ReportColumn(id: "day", title: "Giorno", width: 2),
            ReportColumn(id: "clips", title: "Clip", width: 0.8, alignment: .right),
            ReportColumn(id: "files", title: "File", width: 0.8, alignment: .right),
            ReportColumn(id: "size", title: "Dimensione", width: 1.2, alignment: .right),
            ReportColumn(id: "duration", title: "Durata", width: 1.6, alignment: .right),
            ReportColumn(id: "backup", title: "Backup", width: 2.6),
            ReportColumn(id: "formats", title: "Formati", width: 3.4),
        ]
        var rows: [[ReportCell]] = []
        for name in dayNames {
            let dayFiles = files.filter { $0.dayName == name }
            let media = dayFiles.filter { $0.isMedia }
            let size = dayFiles.reduce(Int64(0)) { $0 + $1.size }
            rows.append([
                ReportCell(name), ReportCell(String(media.count)), ReportCell(String(dayFiles.count)), sizeCell(size),
                totalDuration(media), ReportCell(backupText(dayFiles)),
                ReportCell(joined(media.compactMap(formatText))),
            ])
        }
        var footer: [ReportCell]?
        if dayNames.count > 1 {
            let media = files.filter { $0.isMedia }
            footer = [ReportCell("Totale"), ReportCell(String(media.count)), ReportCell(String(files.count)),
                      sizeCell(files.reduce(Int64(0)) { $0 + $1.size }), totalDuration(media), ReportCell(""), ReportCell("")]
        }
        return ReportBlock(section: .shootingDay, title: "Shooting Day", content: .table(ReportTable(columns: columns, rows: rows, footer: footer)))
    }

    /// "2 copie verificate (tutti OK)" oppure l'elenco dei problemi. Una copia conta solo se TUTTI i file sono OK su quella destinazione.
    static func backupText(_ files: [ClipRecord]) -> String {
        if files.isEmpty { return "Nessun offload" }
        let destCount = files.map { $0.destinationStatuses.count }.max() ?? 0
        var mismatch = 0, error = 0, pending = 0
        var okPerDest = Array(repeating: 0, count: destCount)
        for f in files {
            for (d, st) in f.destinationStatuses.enumerated() {
                switch st {
                case "ok": okPerDest[d] += 1
                case "mismatch": mismatch += 1
                case "error": error += 1
                default: pending += 1
                }
            }
        }
        let completeCopies = okPerDest.filter { $0 == files.count }.count
        if mismatch == 0 && error == 0 && pending == 0 && completeCopies == destCount && destCount > 0 {
            return "\(completeCopies) \(completeCopies == 1 ? "copia verificata" : "copie verificate") (tutti OK)"
        }
        var problems: [String] = []
        if mismatch > 0 { problems.append("\(mismatch) MISMATCH") }
        if error > 0 { problems.append("\(error) ERRORI") }
        if pending > 0 { problems.append("\(pending) non verificati") }
        return "\(completeCopies) di \(destCount) copie complete: " + problems.joined(separator: ", ")
    }

    // MARK: Clips

    static func clipsBlock(_ media: [ClipRecord], columnIDs: [String]) -> ReportBlock {
        let cols = columnIDs.compactMap { ClipColumns.column(id: $0) }
        let columns = cols.map { c -> ReportColumn in
            ReportColumn(id: c.id, title: c.title, width: max(0.6, c.width / 100), alignment: c.id == "size" ? .right : .left)
        }
        let rows = media.map { clip in
            cols.map { col -> ReportCell in
                let text = ClipColumns.value(col, of: clip)
                if col.id == "size" { return ReportCell(text, raw: String(clip.size)) }
                if col.id == "duration", let s = clip.metadata["durationSeconds"] { return ReportCell(text, raw: s) }
                return ReportCell(text)
            }
        }
        return ReportBlock(section: .clips, title: "Clips", subtitle: "\(media.count) clip", content: .table(ReportTable(columns: columns, rows: rows)))
    }

    // MARK: Volume

    static func volumeName(_ root: String) -> String {
        let parts = root.split(separator: "/").map(String.init)
        if parts.count >= 2, parts[0] == "Volumes" { return parts[1] }
        return "Disco interno"
    }

    static func volumeBlocks(files: [ClipRecord], offloads: [OffloadRecord]) -> [ReportBlock] {
        var roots: [String] = []
        for o in offloads { for r in o.destinations where !roots.contains(r) { roots.append(r) } }
        if roots.isEmpty {
            return [ReportBlock(section: .volume, title: "Volume", content: .text("Nessun offload registrato nell'ambito selezionato."))]
        }
        let byOffload = Dictionary(uniqueKeysWithValues: offloads.map { ($0.id, $0) })
        let columns = [
            ReportColumn(id: "name", title: "File", width: 3),
            ReportColumn(id: "location", title: "Posizione", width: 5),
            ReportColumn(id: "size", title: "Dimensione", width: 1.3, alignment: .right),
            ReportColumn(id: "xxh64", title: "XXH64", width: 2.2),
            ReportColumn(id: "status", title: "Stato", width: 1.1),
        ]
        var blocks: [ReportBlock] = []
        for root in roots {
            var entries: [(path: String, clip: ClipRecord, status: String)] = []
            for clip in files {
                guard let off = byOffload[clip.offloadID], let d = off.destinations.firstIndex(of: root) else { continue }
                let status = d < clip.destinationStatuses.count ? clip.destinationStatuses[d] : "pending"
                entries.append((root + "/" + clip.relativePath, clip, status))
            }
            entries.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            let rows = entries.map { e -> [ReportCell] in
                let folder = (e.path as NSString).deletingLastPathComponent
                return [ReportCell(e.clip.name), ReportCell(folder), sizeCell(e.clip.size),
                        ReportCell(e.clip.sourceHash ?? nd), ReportCell(ClipColumns.statusLabel(e.status), raw: e.status)]
            }
            let total = entries.reduce(Int64(0)) { $0 + $1.clip.size }
            let footer = [ReportCell("Totale: \(entries.count) file"), ReportCell(""), sizeCell(total), ReportCell(""), ReportCell("")]
            blocks.append(ReportBlock(section: .volume, title: "Volume «\(volumeName(root))»", subtitle: root,
                                      content: .table(ReportTable(columns: columns, rows: rows, footer: footer))))
        }
        return blocks
    }

    // MARK: Riepiloghi

    static func productionInfo(options: ReportOptions, media: [ClipRecord]) -> ReportBlock {
        func values(_ key: String) -> String { joined(media.compactMap { $0.metadata[key] }) }
        let dates = media.compactMap { $0.metadata["createDate"] }.compactMap { $0.split(separator: " ").first.map(String.init) }.sorted()
        let period: String
        if let first = dates.first, let last = dates.last { period = first == last ? first : "\(first) → \(last)" } else { period = nd }
        let operatorName = options.operatorName.trimmingCharacters(in: .whitespaces)
        let rows: [(String, String)] = [
            ("Progetto", options.projectName),
            ("Operatore", operatorName.isEmpty ? nd : operatorName),
            ("Produzione", values("production")),
            ("Casa di produzione", values("productionCompany")),
            ("Regista", values("director")),
            ("Direttore della fotografia", values("cinematographer")),
            ("Luogo", values("location")),
            ("Camera", values("camera")),
            ("Date di ripresa", period),
        ]
        return ReportBlock(section: .productionInfo, title: "Production Info", content: .keyValues(rows))
    }

    static func clipsOverview(files: [ClipRecord], media: [ClipRecord], offloads: [OffloadRecord], tree: TreeNode, scope: TreeNode) -> ReportBlock {
        func count(_ status: String) -> Int { files.filter { $0.status == status }.count }
        let days = Set(files.map(\.dayName)), bins = Set(files.map(\.binID))
        let dates = offloads.map { $0.finishedAt ?? $0.startedAt }.sorted()
        let rows: [(String, String)] = [
            ("Clip", String(media.count)),
            ("File totali", String(files.count)),
            ("Dimensione totale", Format.bytes(files.reduce(Int64(0)) { $0 + $1.size })),
            ("Durata totale", totalDuration(media).display),
            ("File OK", String(count("ok"))),
            ("File MISMATCH", String(count("mismatch"))),
            ("File ERRORE", String(count("error"))),
            ("File non verificati", String(count("pending"))),
            ("Giorni", String(days.count)),
            ("Bin", String(bins.count)),
            ("Offload eseguiti", String(offloads.count)),
            ("Primo offload", dates.first.map(dateTime) ?? nd),
            ("Ultimo offload", dates.last.map(dateTime) ?? nd),
        ]
        return ReportBlock(section: .clipsOverview, title: "Clips Overview", content: .keyValues(rows))
    }

    static func cameraSummary(_ media: [ClipRecord]) -> ReportBlock {
        struct Key: Hashable { var camera: String; var serial: String }
        var order: [Key] = [], groups: [Key: [ClipRecord]] = [:]
        for c in media {
            let k = Key(camera: c.metadata["camera"] ?? nd, serial: c.metadata["cameraSerial"] ?? nd)
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(c)
        }
        let columns = [
            ReportColumn(id: "camera", title: "Camera", width: 2),
            ReportColumn(id: "serial", title: "Serial", width: 1),
            ReportColumn(id: "firmware", title: "Firmware", width: 1.2),
            ReportColumn(id: "clips", title: "Clip", width: 0.7, alignment: .right),
            ReportColumn(id: "duration", title: "Durata", width: 1.6, alignment: .right),
            ReportColumn(id: "size", title: "Dimensione", width: 1.2, alignment: .right),
            ReportColumn(id: "lenses", title: "Lenti", width: 3),
        ]
        let rows = order.map { k -> [ReportCell] in
            let g = groups[k]!
            return [ReportCell(k.camera), ReportCell(k.serial), ReportCell(joined(g.compactMap { $0.metadata["firmware"] })),
                    ReportCell(String(g.count)), totalDuration(g), sizeCell(g.reduce(Int64(0)) { $0 + $1.size }),
                    ReportCell(joined(g.compactMap { $0.metadata["lens"] }))]
        }
        return ReportBlock(section: .cameraSummary, title: "Camera Summary", content: .table(ReportTable(columns: columns, rows: rows)))
    }

    static func videoFormats(_ media: [ClipRecord]) -> ReportBlock {
        struct Key: Hashable { var codec: String; var resolution: String; var fps: String }
        var order: [Key] = [], groups: [Key: [ClipRecord]] = [:]
        for c in media {
            let k = Key(codec: c.metadata["codec"] ?? nd, resolution: c.metadata["resolution"] ?? nd,
                        fps: c.metadata["frameRate"].map { "\($0) fps" } ?? nd)
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(c)
        }
        let columns = [
            ReportColumn(id: "codec", title: "Codec", width: 3),
            ReportColumn(id: "resolution", title: "Risoluzione", width: 1.5),
            ReportColumn(id: "fps", title: "FPS", width: 1),
            ReportColumn(id: "clips", title: "Clip", width: 0.7, alignment: .right),
            ReportColumn(id: "duration", title: "Durata", width: 1.6, alignment: .right),
            ReportColumn(id: "size", title: "Dimensione", width: 1.2, alignment: .right),
        ]
        let rows = order.map { k -> [ReportCell] in
            let g = groups[k]!
            return [ReportCell(k.codec), ReportCell(k.resolution), ReportCell(k.fps), ReportCell(String(g.count)),
                    totalDuration(g), sizeCell(g.reduce(Int64(0)) { $0 + $1.size })]
        }
        return ReportBlock(section: .videoFormats, title: "Video Formats", content: .table(ReportTable(columns: columns, rows: rows)))
    }
}
