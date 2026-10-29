import Foundation

// Lettori delle famiglie già presenti nell'app, spostati dietro l'interfaccia `MetadataReader` senza cambiarne il comportamento.

// MARK: - ARRI

/// ARRI: ARRIRAW (.ari), HDE (.arx), MXF (Mini, Mini LF, Alexa 35, Amira), ARRI ProRes (.mov).
/// ExifTool riconosce la famiglia e dà i dati del contenitore; `art-cmd` (ARRI Reference Tool, se installato) aggiunge ISO, lente, ND, WB, look, sensor FPS…
/// (valori del PRIMO fotogramma). Su .ari/.arx ExifTool non legge nulla: i dati vengono solo da art-cmd.
public struct ARRIReader: MetadataReader {
    public let family = "ARRI"
    public let extensions: Set<String> = ["ari", "arx", "mxf", "mov"]
    public init() {}

    public func canRead(_ file: ClipFile) -> Bool {
        if file.probe.kind == .arriRaw || ["ari", "arx"].contains(file.ext) { return true }
        guard extensions.contains(file.ext) else { return false }
        // estensione + contenitore: un .mov che in realtà è un altro formato noto non viene provato; byte non riconoscibili → conta l'estensione
        switch file.probe.kind {
        case .mxf, .isoBMFF, .unknown: return true
        default: return false
        }
    }

    public func read(_ file: ClipFile) -> ClipMetadata {
        var values: [String: String] = [:]
        var isARRI = false
        var diagnostics: [MetadataDiagnostic] = []
        var rawTags: [String: Any] = [:]
        var otherVendor = false
        if file.hasExifTool {
            do {
                let tags = try file.exifTags()
                rawTags = tags
                if ARRIMetadataParser.canParse(tags) {
                    isARRI = true
                    values = ARRIMetadataParser.parse(tags)
                } else if let supplier = tags["MXF:ApplicationSupplierName"] as? String, !supplier.trimmingCharacters(in: .whitespaces).isEmpty {
                    otherVendor = true     // ExifTool ha riconosciuto un altro costruttore: non è ARRI
                }
            } catch let e as MetadataError {
                // per .ari/.arx ExifTool può non leggere nulla: se poi art-cmd legge il file l'errore non conta (si riporta solo senza valori)
                diagnostics.append(e.asDiagnostic)
            } catch {}
        }
        // senza ExifTool o per i formati che ExifTool non legge (.ari/.arx) l'unico lettore possibile è art-cmd
        let artOnly = !isARRI && !otherVendor && ["ari", "arx"].contains(file.ext)
        guard isARRI || artOnly else { return .unsupported(diagnostics) }
        if file.hasArtCmd {
            diagnostics += ARRIReader.mergeArtCmd(file, into: &values, isARRI: isARRI || artOnly)
        } else if artOnly {
            diagnostics.append(.note(tr("I file .ari/.arx si leggono solo con art-cmd, che non è installato.")))
        }
        if values.isEmpty, file.probe.kind == .arriRaw {
            // il file ha la firma ARRIRAW ma senza art-cmd non si legge altro: solo l'identità del formato
            var m = ClipMetadata()
            m.family = "ARRI"
            m.cameraMake = "ARRI"
            m.container = "ARRIRAW"
            m.codec = "ARRIRAW"
            m.diagnostics = diagnostics + [.note(tr("File ARRIRAW riconosciuto dalla firma: gli altri metadata richiedono art-cmd."))]
            m.status = .partial
            return m
        }
        guard !values.isEmpty else { return .unsupported(diagnostics) }
        var m = ClipMetadata(columns: values, family: "ARRI")
        // ffprobe/ExifTool completano ciò che art-cmd e l'MXF non danno (numero di fotogrammi, audio…); i valori ARRI prevalgono
        m.fillMissing(from: CameraMediaEngine.gather(file, sidecars: false).metadata)
        m.container = m.container ?? ARRIReader.containerName(file)
        m.rawFields.merge(RawTags.fields(from: rawTags)) { a, _ in a }
        m.diagnostics = diagnostics
        m.status = diagnostics.contains { if case .artCmdFailed = $0 { return true } else { return false } } ? .partial : .read
        return m
    }

    /// Aggiunge i dati di art-cmd (prevalgono dove si sovrappongono). Restituisce le segnalazioni.
    static func mergeArtCmd(_ file: ClipFile, into values: inout [String: String], isARRI: Bool) -> [MetadataDiagnostic] {
        do {
            let extra = ARTMetadataParser.parse(try file.artJSON())
            if !extra.isEmpty {
                values.merge(extra) { _, new in new }
            } else if isARRI {
                return [.artCmdFailed(nil)]
            }
        } catch let e as MetadataError {
            if case .toolMissing = e { return [.toolMissing(e.description)] }
            // su un clip riconosciuto come ARRI l'errore va segnalato; su un file sconosciuto è solo «formato non supportato»
            if isARRI { return [.artCmdFailed(e.description)] }
        } catch {}
        return []
    }

    static func containerName(_ file: ClipFile) -> String? {
        switch file.ext {
        case "mxf": return "MXF"
        case "mov": return "QuickTime"
        case "ari": return "ARRIRAW"
        case "arx": return "ARRIRAW HDE"
        default: return nil
        }
    }
}

/// Ultima possibilità per .mxf/.mov che nessun'altra famiglia ha riconosciuto: ExifTool può non conoscerli, `art-cmd` sì.
public struct ARRIArtCmdFallbackReader: MetadataReader {
    public let family = "ARRI"
    public let extensions: Set<String> = ["mxf", "mov"]
    public init() {}

    public func canRead(_ file: ClipFile) -> Bool { file.hasArtCmd && extensions.contains(file.ext) }

    public func read(_ file: ClipFile) -> ClipMetadata {
        var values: [String: String] = [:]
        let diagnostics = ARRIReader.mergeArtCmd(file, into: &values, isARRI: false)
        guard !values.isEmpty else { return .unsupported(diagnostics) }
        var m = ClipMetadata(columns: values, family: "ARRI")
        // i dati tecnici del file (ffprobe/ExifTool: durata, fps, codec, audio…) completano quelli di art-cmd, che prevalgono
        // (serve per esempio ai ProRes ARRI .mov, dove ExifTool non riconosce la camera)
        m.fillMissing(from: CameraMediaEngine.gather(file, sidecars: false).metadata)
        m.container = m.container ?? ARRIReader.containerName(file)
        m.diagnostics = diagnostics
        m.status = .read
        return m
    }
}

// MARK: - Audio broadcast (BWF)

/// WAV/BWF: dati tecnici da ffprobe + intestazione broadcast (bext + iXML: scena, take, nastro, tracce, timecode, registratore).
public struct BWFReader: MetadataReader {
    public let family = "Audio (BWF)"
    public let extensions: Set<String> = ["wav", "bwf", "w64"]
    public init() {}

    public func canRead(_ file: ClipFile) -> Bool { file.probe.kind == .riffWave }

    public func read(_ file: ClipFile) -> ClipMetadata {
        var values: [String: String] = [:]
        var diagnostics: [MetadataDiagnostic] = []
        if file.hasFFprobe {
            do { values = FFprobeMetadataParser.parse(try file.ffprobeJSON()) } catch let e as MetadataError { diagnostics.append(e.asDiagnostic) } catch {}
        }
        var bwfTimecode: String?
        if let bwf = BroadcastWaveReader.read(path: file.path) {
            let parsed = BroadcastWaveMetadataParser.parse(bwf)
            values.merge(parsed) { _, new in new }
            bwfTimecode = parsed["timecode"]
        }
        guard !values.isEmpty else { return .unsupported(diagnostics) }
        var m = ClipMetadata(columns: values, family: family)
        m.container = "WAV"
        m.bwfTimecode = bwfTimecode
        m.diagnostics = diagnostics
        m.status = .read
        return m
    }
}

// MARK: - Qualunque altro formato: ffprobe

/// Formati senza lettore dedicato (MPG, LRF, MP4, ProRes, GoPro, DSLR, iPhone…): solo ciò che il file dichiara, via ffprobe.
public struct FFprobeGenericReader: MetadataReader {
    public let family = "Generic (ffprobe)"
    public let extensions: Set<String> = []
    public init() {}

    public func canRead(_ file: ClipFile) -> Bool { file.hasFFprobe }

    public func read(_ file: ClipFile) -> ClipMetadata {
        do {
            let values = FFprobeMetadataParser.parse(try file.ffprobeJSON())
            guard !values.isEmpty else { return .unsupported() }
            var m = ClipMetadata(columns: values, family: family)
            m.status = .read
            return m
        } catch let e as MetadataError {
            return .unsupported([e.asDiagnostic])
        } catch {
            return .unsupported()
        }
    }
}

extension NSNumber {
    /// true solo per i veri «true/false» del JSON. Un numero 0 o 1 NON è un booleano (`value is Bool` darebbe true anche per 0 e 1:
    /// scartava per esempio un tint di 0 o un roll di 0 dei clip ARRI).
    var isJSONBoolean: Bool { String(cString: objCType) == "c" }
}

extension MetadataError {
    var asDiagnostic: MetadataDiagnostic {
        switch self {
        case .toolMissing(let m): return .toolMissing(m)
        case .toolFailed(let m), .invalidOutput(let m): return .toolFailed(m)
        }
    }
}

/// Tag grezzi di ExifTool da conservare in `rawFields` (nome «Gruppo:Tag»): niente dati di sistema del file, niente blocchi binari.
enum RawTags {
    static let ignoredGroups: Set<String> = ["System", "File", "ExifTool", "SourceFile"]

    static func fields(from tags: [String: Any], maxValueLength: Int = 500) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in tags {
            let group = key.split(separator: ":").first.map(String.init) ?? ""
            if ignoredGroups.contains(group) || key == "SourceFile" { continue }
            let text: String
            switch value {
            case let s as String: text = s
            case let n as NSNumber: text = n.isJSONBoolean ? (n.boolValue ? "true" : "false") : n.stringValue
            case let a as [Any]: text = a.map { "\($0)" }.joined(separator: " ")
            default: continue
            }
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty || t.hasPrefix("(Binary data") || t.count > maxValueLength { continue }
            out[key] = t
        }
        return out
    }
}

public extension ReaderRegistry {
    /// I lettori nell'ordine di prova: famiglie specifiche, poi i ripieghi generici.
    static func standard() -> ReaderRegistry {
        ReaderRegistry(readers: [
            ARRIReader(),
            REDReader(),
            PhantomReader(),
            CameraFamilyReader(family: "DJI", extensions: ["mov", "mp4", "dng", "lrf", "mxf"], enrich: DJIMapper.enrich),
            CameraFamilyReader(family: "Sony", extensions: ["mxf", "mp4", "mts", "m2ts", "mov", "arw", "sr2", "srf", "arq"],
                               exclusiveExtensions: ["arw", "sr2", "srf", "arq"]),
            CameraFamilyReader(family: "Canon", extensions: ["mxf", "mp4", "mts", "m2ts", "mov", "crm", "cr3", "cr2", "crw", "rmf"],
                               exclusiveExtensions: ["crm", "cr3", "cr2", "crw", "rmf"]),
            CameraFamilyReader(family: "Panasonic", extensions: ["mxf", "mp4", "mov", "mts", "m2ts", "rw2", "rwl", "dng"],
                               exclusiveExtensions: ["rw2", "rwl"]),
            CameraFamilyReader(family: "Blackmagic", extensions: ["braw", "mov", "dng", "mxf"], exclusiveExtensions: ["braw"],
                               identity: ("BRAW", "Blackmagic RAW")),
            CameraFamilyReader(family: "Kinefinity", extensions: ["krw", "mov", "mxf", "dng"], exclusiveExtensions: ["krw"],
                               identity: ("KRW", "Kinefinity KineRAW")),
            BWFReader(),
            ARRIArtCmdFallbackReader(),
            GenericMediaReader(),
            FFprobeGenericReader(),
        ])
    }
}
