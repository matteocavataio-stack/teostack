import Foundation

/// Contenuto di una cella dei campi (Clips e Thumbnail Report).
enum FieldCell {
    case empty
    case text(String)
    case preview            // anteprima del clip (immagine)
    case flag               // bandierina (icona)
    case rating             // cinque stelle vuote
    case label(String)      // cerchio + testo («No Label»)
}

/// Valori dei campi per ogni file. Si riempiono SOLO i campi che l'app conosce; gli altri restano vuoti, come nel formato di riferimento.
/// I valori derivano dai dati letti dai clip (ExifTool / art-cmd) e dai calcoli dell'offload: nulla è inventato.
enum ReportFields {
    static func cell(_ title: String, item: ReportItem, ctx: ReportContext) -> FieldCell {
        func text(_ s: String?) -> FieldCell { (s?.isEmpty ?? true) ? .empty : .text(s!) }
        let clipOnly = item.isClip
        switch title {
        case "Preview": return .preview
        case "Name": return .text(item.name)
        case "Duration": return text(item.durationSeconds.map(ReportFormatting.duration))
        case "Frames": return text(item.frames.map(String.init))
        case "File Size": return .text(ReportFormatting.size(item.clip.size))
        case "Source File Date": return text(item.clip.modifiedAt.map(ReportFormatting.dateTime))
        case "Registration Date": return .text(ReportFormatting.dateTime(item.clip.offloadDate))
        case "Scene": return text(item.meta("scene"))
        case "Take": return text(item.meta("take"))
        case "Camera": return text(item.meta("cameraIndex"))
        case "Shooting/Recording Date": return text(item.meta("createDate").flatMap(ReportFormatting.recordingDate))
        case "Flag/Circled": return .flag
        case "Rating": return .rating
        case "Label": return .label("No Label")
        case "FPS of TC": return text(clipOnly ? item.meta("frameRate") : nil)
        case "TC Start": return text(item.meta("timecode").map(ReportFormatting.timecode))
        case "TC End":
            guard let tc = item.meta("timecode"), let frames = item.frames, let fps = item.fps else { return .empty }
            return text(ReportFormatting.timecodeEnd(start: tc, frames: frames, fps: fps))
        case "Reel/Tape": return text(item.meta("reel"))
        case "In/Out Duration": return text(item.frames.map(String.init))
        case "EI/ISO (clip)", "EI/ISO (current)": return text(item.meta("iso"))
        case "WB (clip)", "WB (current)": return text(item.meta("whiteBalance")?.components(separatedBy: ",").first)
        case "Tint (clip)", "Tint (current)": return text(item.meta("tint"))
        case "Shutter": return text(item.meta("shutter").map { $0 + "s" })
        case "Shutter Angle":
            guard let s = item.meta("shutter"), s.hasPrefix("1/"), let denominator = Double(s.dropFirst(2)), denominator > 0,
                  let fps = item.meta("sensorFPS").flatMap(Double.init) ?? item.fps else { return .empty }
            return text(String(format: "%.1f° @ %@fps", 360 * fps / denominator, trimmed(fps)))
        case "Sensor FPS": return text(item.meta("sensorFPS"))
        case "ND Filter": return text(item.meta("ndFilter"))
        case "Look Info": return text(item.meta("lookInfo"))
        case "Camera Tilt [°]": return text(item.meta("tilt"))
        case "Camera Roll [°]": return text(item.meta("roll"))
        case "Manufacturer": return text(item.meta("manufacturer"))
        case "Recorder Model": return text(item.meta("camera"))
        case "Serial Number": return text(item.meta("cameraSerial"))
        case "Firmware Version": return text(item.meta("firmware"))
        case "Lens Model": return text(item.meta("lens"))
        case "Lens Serial": return text(item.meta("lensSerial"))
        case "Focal Length": return text(item.meta("focalLength"))
        case "Focus Distance": return text(item.meta("focusDistance"))
        case "Director": return text(item.meta("director"))
        case "Production": return text(item.meta("production"))
        case "Cinematographer": return text(item.meta("cinematographer"))
        case "Location": return text(item.meta("location"))
        case "Codec": return text(item.meta("codec"))
        case "File Type": return text(item.fileExtension)
        case "Resolution": return text(item.meta("resolution"))
        case "Project FPS": return text(item.meta("frameRate"))
        case "Rec. Color Space":
            guard let cs = item.meta("colorSpace") else { return .empty }
            let parts = cs.components(separatedBy: " / ")              // «AWG4 / LogC4» → «LogC4, AWG4»
            return text(parts.count == 2 ? "\(parts[1]), \(parts[0])" : cs)
        case "Audio Codec": return text(item.meta("audioCodec"))
        case "Audio Tracks": return text(item.meta("audioChannels"))
        case "Audio Sample Rate": return text(item.meta("audioSampleRate"))
        case "Audio Bit Depth": return text(item.meta("audioBitDepth"))
        case "Bin Name": return .text(item.clip.binName)
        case "Volumes": return text(item.volumes.joined(separator: ", "))
        case "Backups": return .text(String(item.backups))
        case "Verified Backups": return .text(String(item.verifiedBackups))
        case "Verification State": return .text(item.verificationState)
        case "Resources":
            let lines = ([item.sourcePath].compactMap { $0 }) + item.destinationPaths
            return lines.isEmpty ? .empty : .text(lines.joined(separator: "\n"))
        case "XXH64": return text(item.clip.sourceHash)
        case "Hash Values": return text(item.clip.sourceHash.map { "XXH64BE:" + $0 })
        default: return .empty
        }
    }

    private static func trimmed(_ v: Double) -> String {
        var s = String(format: "%.3f", v)
        while s.contains(".") && (s.hasSuffix("0") || s.hasSuffix(".")) { s.removeLast() }
        return s
    }
}
