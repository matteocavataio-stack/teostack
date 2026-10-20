import Foundation

/// Cartella di destinazione con i file VERIFICATI da inserire in una ASC MHL.
public struct MHLTarget: Equatable {
    public var root: String
    public var entries: [MHLFileEntry]
    public var skipped: [String]          // file registrati OK ma non inclusi (assenti o dimensione diversa su disco)
    public var unlistedOnDisk: Int        // file presenti nella cartella ma non verificati dall'app (non inclusi)
    public var rootExists: Bool
}

public enum MHLTargets {
    /// Per ogni cartella di destinazione degli offload sotto il nodo: i file con stato OK su quella destinazione, controllati sul disco.
    public static func collect(store: ProjectStore, nodeID: Int64) throws -> [MHLTarget] {
        let offloads = try store.offloads(underNode: nodeID)
        let clips = try store.clips(underNode: nodeID, mediaOnly: false)
        let byOffload = Dictionary(uniqueKeysWithValues: offloads.map { ($0.id, $0) })
        var roots: [String] = []
        for o in offloads { for r in o.destinations where !roots.contains(r) { roots.append(r) } }

        var targets: [MHLTarget] = []
        for root in roots {
            var entries: [MHLFileEntry] = []
            var skipped: [String] = []
            let rootExists = FileManager.default.fileExists(atPath: root)
            for clip in clips {
                guard let off = byOffload[clip.offloadID], let d = off.destinations.firstIndex(of: root),
                      d < clip.destinationStatuses.count, clip.destinationStatuses[d] == "ok", let hash = clip.sourceHash else { continue }
                let path = (root as NSString).appendingPathComponent(clip.relativePath)
                guard let st = try? DiskIO.lstatInfo(path: path), st.isRegular else {
                    skipped.append("\(clip.relativePath): non trovato sul disco"); continue
                }
                guard st.size == clip.size else {
                    skipped.append("\(clip.relativePath): dimensione diversa da quella verificata (\(st.size) invece di \(clip.size) byte)"); continue
                }
                entries.append(MHLFileEntry(relativePath: clip.relativePath, size: st.size, modified: st.times.modification,
                                            xxh64: hash, hashDate: off.finishedAt ?? off.startedAt))
            }
            // un file può comparire due volte se due offload hanno scritto lo stesso percorso: tengo il primo
            var seen = Set<String>()
            entries = entries.filter { seen.insert($0.relativePath).inserted }
            targets.append(MHLTarget(root: root, entries: entries, skipped: skipped,
                                     unlistedOnDisk: rootExists ? unlisted(root: root, known: seen) : 0, rootExists: rootExists))
        }
        return targets
    }

    private static func unlisted(root: String, known: Set<String>) -> Int {
        guard let e = FileManager.default.enumerator(atPath: root) else { return 0 }
        var n = 0
        for case let rel as String in e {
            if rel == ASCMHL.folderName || rel.hasPrefix(ASCMHL.folderName + "/") { continue }
            let name = (rel as NSString).lastPathComponent
            if name == ".DS_Store" { continue }
            guard let st = try? DiskIO.lstatInfo(path: (root as NSString).appendingPathComponent(rel)), st.isRegular else { continue }
            if !known.contains(rel) { n += 1 }
        }
        return n
    }
}
