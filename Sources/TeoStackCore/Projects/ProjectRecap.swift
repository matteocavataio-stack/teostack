import Foundation

/// Riepilogo di quanto è stato scaricato in una cartella del progetto (giorno, sottocartella, Library o bin).
/// Solo dati registrati: i valori che non si conoscono non vengono stimati, ma dichiarati («senza durata», «senza metadata»).
public struct ProjectRecap: Equatable {
    /// Un formato (codec, risoluzione, estensione) con i clip che lo usano.
    public struct FormatLine: Equatable {
        public var label: String
        public var clips: Int
        public var bytes: Int64
        /// Formato audio (nella tabella «clips» sono file audio).
        public var isAudio = false
    }

    /// Spazio dei file copiati e verificati OK (clip e file collegati: XML, sidecar, audio…), contati una volta sola.
    public var verifiedBytes: Int64 = 0
    /// File registrati ma NON verificati OK (non entrano nello spazio indicato).
    public var notVerifiedFiles = 0
    public var fileCount = 0
    /// Clip video (file media).
    public var clipCount = 0
    /// Clip audio (WAV, BWF…): contati a parte, non sommati ai clip video né alla durata.
    public var audioCount = 0
    /// Audio senza codec letto (metadata non letti).
    public var audioWithoutFormat = 0
    /// Schede scaricate: offload completati che hanno portato almeno un file (una stessa scheda ripetuta nello stesso bin conta una volta).
    public var cardCount = 0
    /// Offload annullati o interrotti, non contati come schede.
    public var incompleteOffloads = 0
    /// Durata totale dei clip di cui si conosce la durata.
    public var durationSeconds: Double = 0
    public var clipsWithDuration = 0
    public var clipsWithoutDuration: Int { clipCount - clipsWithDuration }
    public var formats: [FormatLine] = []
    /// Clip senza codec né risoluzione letti (servono i metadata per classificarli).
    public var clipsWithoutFormat = 0

    public var isEmpty: Bool { fileCount == 0 && cardCount == 0 && incompleteOffloads == 0 }

    public init() {}

    /// `clips` deve contenere TUTTI i file registrati (non solo i video); `offloads` gli offload della stessa cartella.
    public static func make(clips: [ClipRecord], offloads: [OffloadRecord]) -> ProjectRecap {
        // Lo stesso file offloadato due volte nello stesso bin (stesso percorso, dimensione e hash) si conta una volta:
        // vince la copia verificata OK, a parità la più recente.
        var unique: [String: ClipRecord] = [:]
        for clip in clips {
            let key = "\(clip.binID)|\(clip.relativePath)|\(clip.size)|\(clip.sourceHash ?? "")"
            if let current = unique[key] {
                let better = (clip.status == "ok" && current.status != "ok")
                    || ((clip.status == "ok") == (current.status == "ok") && clip.offloadID > current.offloadID)
                if better { unique[key] = clip }
            } else {
                unique[key] = clip
            }
        }

        var recap = ProjectRecap()
        let completedIDs = Set(offloads.filter { $0.outcome == "completed" }.map(\.id))
        recap.incompleteOffloads = offloads.filter { $0.outcome != "completed" }.count
        var cardIDs = Set<Int64>()
        var formats: [String: FormatLine] = [:]

        for clip in unique.values {
            recap.fileCount += 1
            if clip.status == "ok" { recap.verifiedBytes += clip.size } else { recap.notVerifiedFiles += 1 }
            if completedIDs.contains(clip.offloadID) { cardIDs.insert(clip.offloadID) }
            if clip.isAudio {
                recap.audioCount += 1
                let codec = clip.metadata["audioCodec"]?.trimmingCharacters(in: .whitespaces) ?? ""
                let rate = clip.metadata["audioSampleRate"]?.trimmingCharacters(in: .whitespaces) ?? ""
                if codec.isEmpty && rate.isEmpty { recap.audioWithoutFormat += 1 }
                let ext = (clip.name as NSString).pathExtension.uppercased()
                let parts = [codec, clip.metadata["audioBitDepth"].map { "\($0) bit" } ?? "", rate.isEmpty ? "" : "\(rate) Hz", ext.isEmpty ? "" : ".\(ext)"]
                let label = parts.filter { !$0.isEmpty }.joined(separator: " · ")
                let key = "audio|" + label
                var line = formats[key] ?? FormatLine(label: label.isEmpty ? ClipColumns.notAvailable : label, clips: 0, bytes: 0, isAudio: true)
                line.clips += 1
                line.bytes += clip.size
                formats[key] = line
                continue
            }
            guard clip.isMedia else { continue }
            recap.clipCount += 1
            if let raw = clip.metadata["durationSeconds"], let seconds = Double(raw), seconds.isFinite, seconds >= 0 {
                recap.durationSeconds += seconds
                recap.clipsWithDuration += 1
            }
            let codec = clip.metadata["codec"]?.trimmingCharacters(in: .whitespaces) ?? ""
            let resolution = clip.metadata["resolution"]?.trimmingCharacters(in: .whitespaces) ?? ""
            if codec.isEmpty && resolution.isEmpty { recap.clipsWithoutFormat += 1 }
            let ext = (clip.name as NSString).pathExtension.uppercased()
            let label = ([codec, resolution].filter { !$0.isEmpty } + [ext.isEmpty ? "" : ".\(ext)"].filter { !$0.isEmpty }).joined(separator: " · ")
            let key = label.isEmpty ? "?" : label
            var line = formats[key] ?? FormatLine(label: label.isEmpty ? ClipColumns.notAvailable : label, clips: 0, bytes: 0)
            line.clips += 1
            line.bytes += clip.size
            formats[key] = line
        }
        recap.cardCount = cardIDs.count
        recap.formats = formats.values.sorted { ($0.isAudio ? 1 : 0, $1.clips, $0.label) < ($1.isAudio ? 1 : 0, $0.clips, $1.label) }
        return recap
    }
}
