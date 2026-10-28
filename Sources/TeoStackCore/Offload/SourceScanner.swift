import Foundation

/// Scansione di SOLA LETTURA della sorgente (nessuna scrittura, nessuna modifica).
public enum SourceScanner {
    /// Voci create dal sistema operativo sui volumi: non fanno parte del girato e non vengono copiate.
    public static let systemEntries: Set<String> = [
        ".Spotlight-V100", ".fseventsd", ".Trashes", ".TemporaryItems", ".DocumentRevisions-V100",
        ".DS_Store", "$RECYCLE.BIN", "System Volume Information",
    ]

    public static func scan(root: URL, isCancelled: () -> Bool = { false }) throws -> ScanResult {
        let rootPath = root.standardizedFileURL.path
        let rootInfo = try DiskIO.lstatInfo(path: rootPath)
        guard rootInfo.isDirectory else {
            throw DiskIOError(code: ENOTDIR, operation: tr("La sorgente non è una cartella"), path: rootPath)
        }
        var files: [SourceFile] = []
        var dirs: [SourceDirectory] = []
        var skipped: [SkippedItem] = []
        try walk(absolute: rootPath, relative: "", files: &files, dirs: &dirs, skipped: &skipped, isCancelled: isCancelled)
        return ScanResult(root: root, files: files, directories: dirs, skipped: skipped)
    }

    private static func walk(absolute: String, relative: String,
                             files: inout [SourceFile], dirs: inout [SourceDirectory], skipped: inout [SkippedItem],
                             isCancelled: () -> Bool) throws {
        if isCancelled() { throw CancellationError() }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: absolute).sorted()
        } catch {
            skipped.append(SkippedItem(relativePath: relative.isEmpty ? "." : relative,
                                       reason: tr("cartella non leggibile: {0}", error.localizedDescription)))
            return
        }
        for name in names {
            if systemEntries.contains(name) { continue }
            let abs = absolute + "/" + name
            let rel = relative.isEmpty ? name : relative + "/" + name
            let info: DiskIO.StatInfo
            do { info = try DiskIO.lstatInfo(path: abs) } catch {
                skipped.append(SkippedItem(relativePath: rel, reason: "\(error)"))
                continue
            }
            if info.isSymlink {
                skipped.append(SkippedItem(relativePath: rel, reason: tr("collegamento simbolico (non copiato)")))
            } else if info.isDirectory {
                dirs.append(SourceDirectory(relativePath: rel, modificationDate: info.times.modification,
                                            creationDate: info.times.creation))
                try walk(absolute: abs, relative: rel, files: &files, dirs: &dirs, skipped: &skipped, isCancelled: isCancelled)
            } else if info.isRegular {
                files.append(SourceFile(relativePath: rel, size: info.size,
                                        modificationDate: info.times.modification, creationDate: info.times.creation))
            } else {
                skipped.append(SkippedItem(relativePath: rel, reason: tr("tipo di file speciale (non copiato)")))
            }
        }
    }
}
