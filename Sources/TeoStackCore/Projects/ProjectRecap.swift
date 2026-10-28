import Foundation

/// Riepilogo di quanto c'è in una cartella del progetto (giorno, sottocartella, Library o bin), con le stesse tabelle del «Shooting Day Report»
/// (Clips Overview, Backups (Verified), Video Formats, Camera Sums).
/// Solo dati registrati: quello che non si conosce non viene stimato, ma dichiarato (durata parziale, formato senza metadata…).
public struct ProjectRecap: Equatable {
    /// Una riga di conteggi: clip, file, peso e durata.
    public struct Group: Equatable {
        public var clips = 0
        public var files = 0
        public var size: Int64 = 0
        public var durationSeconds = 0.0
        public var clipsWithDuration = 0

        public var clipsWithoutDuration: Int { clips - clipsWithDuration }

        mutating func add(_ clip: ClipRecord, isClip: Bool) {
            files += 1
            size += clip.size
            guard isClip else { return }
            clips += 1
            if let seconds = ProjectRecap.durationSeconds(of: clip) {
                durationSeconds += seconds
                clipsWithDuration += 1
            }
        }

        static func + (a: Group, b: Group) -> Group {
            Group(clips: a.clips + b.clips, files: a.files + b.files, size: a.size + b.size,
                  durationSeconds: a.durationSeconds + b.durationSeconds, clipsWithDuration: a.clipsWithDuration + b.clipsWithDuration)
        }
    }

    public struct BackupRow: Equatable {
        public let label: String        // "3+", "2", "1", "0"
        public var clips = 0
    }

    public struct VideoFormat: Equatable {
        public var codec: String?
        public var fileType: String
        public var resolution: String?
        public var fps: String?
        public var group = Group()
    }

    public struct AudioFormat: Equatable {
        public var codec: String?
        public var sampleRate: String?
        public var bitDepth: String?
        public var channels: String?
        public var group = Group()
    }

    public struct CameraRow: Equatable {
        public var camera: String?
        public var reelCount = 0
        /// Somma dei frame (durata × FPS) dei clip di cui si conoscono entrambi; nil se nessuno.
        public var frames: Int?
        public var group = Group()
    }

    public var video = Group()
    public var audio = Group()
    public var other = Group()
    public var total: Group { video + audio + other }

    /// Clip (video e audio) per numero di copie verificate OK: 3+, 2, 1, 0. Un file importato ha 0 copie verificate.
    public var backups = [BackupRow(label: "3+"), BackupRow(label: "2"), BackupRow(label: "1"), BackupRow(label: "0")]
    public var videoFormats: [VideoFormat] = []
    public var audioFormats: [AudioFormat] = []
    public var cameras: [CameraRow] = []

    /// Schede scaricate: offload completati che hanno portato almeno un file (la stessa scheda ripetuta nello stesso bin conta una volta).
    public var cardCount = 0
    /// Offload annullati o interrotti (non contati come schede).
    public var incompleteOffloads = 0
    /// Peso dei file copiati e verificati OK.
    public var verifiedBytes: Int64 = 0
    /// File importati senza copia (non verificati: compaiono nella riga «0» dei backup).
    public var importedFiles = 0
    /// File con MISMATCH, errore o copia incompiuta.
    public var problemFiles = 0
    /// Clip video senza codec né risoluzione (metadata non letti).
    public var videoWithoutFormat = 0
    public var audioWithoutFormat = 0

    public var isEmpty: Bool { total.files == 0 && incompleteOffloads == 0 }

    public init() {}

    static func durationSeconds(of clip: ClipRecord) -> Double? {
        guard let raw = clip.metadata["durationSeconds"], let s = Double(raw), s.isFinite, s >= 0 else { return nil }
        return s
    }

    private static func meta(_ clip: ClipRecord, _ key: String) -> String? {
        let v = clip.metadata[key]?.trimmingCharacters(in: .whitespaces)
        return (v?.isEmpty ?? true) ? nil : v
    }

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
        recap.incompleteOffloads = offloads.filter { $0.outcome != "completed" && $0.outcome != "imported" }.count
        var cardIDs = Set<Int64>()
        var videoFormats: [String: VideoFormat] = [:]
        var audioFormats: [String: AudioFormat] = [:]
        var cameraClips: [String: [ClipRecord]] = [:]
        var cameraOrder: [String] = []

        // ordine stabile (per percorso) così le tabelle non cambiano da una lettura all'altra
        for clip in unique.values.sorted(by: { ($0.binName, $0.relativePath, $0.id) < ($1.binName, $1.relativePath, $1.id) }) {
            let isVideo = clip.isMedia, isAudio = clip.isAudio
            if isVideo { recap.video.add(clip, isClip: true) } else if isAudio { recap.audio.add(clip, isClip: true) } else { recap.other.add(clip, isClip: false) }

            switch clip.status {
            case "ok": recap.verifiedBytes += clip.size
            case ClipRecord.importedStatus: recap.importedFiles += 1
            default: recap.problemFiles += 1
            }
            if completedIDs.contains(clip.offloadID) { cardIDs.insert(clip.offloadID) }
            guard isVideo || isAudio else { continue }

            let verified = clip.destinationStatuses.filter { $0 == "ok" }.count
            recap.backups[verified >= 3 ? 0 : (3 - verified)].clips += 1
            let ext = (clip.name as NSString).pathExtension.uppercased()

            if isVideo {
                let codec = meta(clip, "codec"), resolution = meta(clip, "resolution"), fps = meta(clip, "frameRate")
                if codec == nil && resolution == nil { recap.videoWithoutFormat += 1 }
                let key = [codec ?? "", ext, resolution ?? "", fps ?? ""].joined(separator: "|")
                var f = videoFormats[key] ?? VideoFormat(codec: codec, fileType: ext, resolution: resolution, fps: fps)
                f.group.add(clip, isClip: true)
                videoFormats[key] = f

                let cameraKey = meta(clip, "cameraIndex") ?? ""
                if cameraClips[cameraKey] == nil { cameraOrder.append(cameraKey) }
                cameraClips[cameraKey, default: []].append(clip)
            } else {
                let codec = meta(clip, "audioCodec"), rate = meta(clip, "audioSampleRate")
                if codec == nil && rate == nil { recap.audioWithoutFormat += 1 }
                let bits = meta(clip, "audioBitDepth"), channels = meta(clip, "audioChannels")
                let key = [codec ?? "", rate ?? "", bits ?? "", channels ?? ""].joined(separator: "|")
                var f = audioFormats[key] ?? AudioFormat(codec: codec, sampleRate: rate, bitDepth: bits, channels: channels)
                f.group.add(clip, isClip: true)
                audioFormats[key] = f
            }
        }
        recap.cardCount = cardIDs.count
        recap.videoFormats = videoFormats.values.sorted {
            ($1.group.clips, $0.codec ?? "", $0.resolution ?? "", $0.fps ?? "") < ($0.group.clips, $1.codec ?? "", $1.resolution ?? "", $1.fps ?? "")
        }
        recap.audioFormats = audioFormats.values.sorted {
            ($1.group.clips, $0.codec ?? "", $0.sampleRate ?? "") < ($0.group.clips, $1.codec ?? "", $1.sampleRate ?? "")
        }
        recap.cameras = cameraOrder.sorted().map { key in
            let items = cameraClips[key] ?? []
            var row = CameraRow(camera: key.isEmpty ? nil : key)
            for c in items { row.group.add(c, isClip: true) }
            row.reelCount = Set(items.map { meta($0, "reel") ?? "" }).count
            let frames = items.compactMap { c -> Int? in
                guard let d = durationSeconds(of: c), let f = meta(c, "frameRate").flatMap(Double.init) else { return nil }
                return Int((d * f).rounded())
            }
            row.frames = frames.isEmpty ? nil : frames.reduce(0, +)
            return row
        }
        return recap
    }
}
