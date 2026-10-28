import Foundation

/// Programmi esterni a disposizione dei lettori (tutti opzionali: un lettore usa quello che c'è e lo dichiara in `diagnostics`).
public struct ReaderTools {
    public var exiftool: ExifToolRunner?
    public var ffprobe: FFprobeRunner?
    public var artCmd: ARTCmdRunner?

    public init(exiftool: ExifToolRunner? = nil, ffprobe: FFprobeRunner? = nil, artCmd: ARTCmdRunner? = nil) {
        self.exiftool = exiftool
        self.ffprobe = ffprobe
        self.artCmd = artCmd
    }

    public static func detect() -> ReaderTools {
        ReaderTools(exiftool: ExifToolRunner.locate(), ffprobe: FFprobeRunner.locate(), artCmd: ARTCmdRunner.locate())
    }

    public var isEmpty: Bool { exiftool == nil && ffprobe == nil && artCmd == nil }
}

/// Un file da leggere: il percorso, il riconoscimento del formato e le letture degli strumenti esterni (fatte una sola volta, solo se servono).
/// Sola lettura: nessun metodo scrive sul file.
public final class ClipFile {
    public let url: URL
    public let probe: FileProbe
    public let tools: ReaderTools

    private var exifResult: Result<[String: Any], MetadataError>?
    private var ffprobeResult: Result<[String: Any], MetadataError>?
    private var artResult: Result<[String: Any], MetadataError>?
    private let exifOverride: (() throws -> [String: Any])?
    private let ffprobeOverride: (() throws -> [String: Any])?
    private let artOverride: (() throws -> [String: Any])?

    public init(url: URL, tools: ReaderTools, probe: FileProbe? = nil,
                exifOverride: (() throws -> [String: Any])? = nil,
                ffprobeOverride: (() throws -> [String: Any])? = nil,
                artOverride: (() throws -> [String: Any])? = nil) {
        self.url = url
        self.tools = tools
        self.probe = probe ?? FileProbe(url: url)
        self.exifOverride = exifOverride
        self.ffprobeOverride = ffprobeOverride
        self.artOverride = artOverride
    }

    public var path: String { url.path }
    public var ext: String { probe.ext }

    /// Tag di ExifTool (`-json -G1 -n`), letti una volta sola.
    public func exifTags() throws -> [String: Any] {
        if exifResult == nil {
            exifResult = capture {
                if let exifOverride { return try exifOverride() }
                guard let exiftool = tools.exiftool else { throw MetadataError.toolMissing(tr("ExifTool non è installato.")) }
                return try exiftool.read(file: path)
            }
        }
        return try exifResult!.get()
    }

    public func ffprobeJSON() throws -> [String: Any] {
        if ffprobeResult == nil {
            ffprobeResult = capture {
                if let ffprobeOverride { return try ffprobeOverride() }
                guard let ffprobe = tools.ffprobe else { throw MetadataError.toolMissing(tr("ffprobe non è installato.")) }
                return try ffprobe.read(file: path)
            }
        }
        return try ffprobeResult!.get()
    }

    public func artJSON() throws -> [String: Any] {
        if artResult == nil {
            artResult = capture {
                if let artOverride { return try artOverride() }
                guard let art = tools.artCmd else { throw MetadataError.toolMissing(tr("art-cmd non è installato.")) }
                return try art.read(file: path)
            }
        }
        return try artResult!.get()
    }

    public var hasExifTool: Bool { exifOverride != nil || tools.exiftool != nil }
    public var hasFFprobe: Bool { ffprobeOverride != nil || tools.ffprobe != nil }
    public var hasArtCmd: Bool { artOverride != nil || tools.artCmd != nil }

    private func capture(_ body: () throws -> [String: Any]) -> Result<[String: Any], MetadataError> {
        do { return .success(try body()) }
        catch let e as MetadataError { return .failure(e) }
        catch { return .failure(.toolFailed(error.localizedDescription)) }
    }
}

/// Lettore di una famiglia di formati. Non lancia mai errori: un file non leggibile dà `.unsupported` o `.failed`.
public protocol MetadataReader {
    /// Nome della famiglia («ARRI», «RED», «Sony»…).
    var family: String { get }
    /// Estensioni tipiche (informativo; il riconoscimento usa anche i primi byte).
    var extensions: Set<String> { get }
    /// Il lettore può provare questo file? (estensione E contenitore; senza leggere tutto il file)
    func canRead(_ file: ClipFile) -> Bool
    /// Legge i metadata. `.unsupported` = «non è mio»: il registry passa al lettore successivo.
    func read(_ file: ClipFile) -> ClipMetadata
}

extension MetadataReader {
    public func canRead(url: URL) -> Bool { canRead(ClipFile(url: url, tools: ReaderTools())) }
}

/// Instrada ogni file al lettore giusto, in ordine di registrazione. Per aggiungere una famiglia basta registrare un lettore.
public final class ReaderRegistry {
    public private(set) var readers: [MetadataReader]

    public init(readers: [MetadataReader] = []) {
        self.readers = readers
    }

    public func register(_ reader: MetadataReader) { readers.append(reader) }

    /// Legge `file` con il primo lettore che lo riconosce e produce valori. Nessun lettore → `.unsupported` (file generico: solo hash).
    public func read(_ file: ClipFile) -> ClipMetadata {
        var carried: [MetadataDiagnostic] = []
        var best: ClipMetadata?
        for reader in readers where reader.canRead(file) {
            var result = reader.read(file)
            if result.family == nil { result.family = reader.family }
            switch result.status {
            case .unsupported:
                carried += result.diagnostics.filter { if case .note = $0 { return false } else { return true } }
            case .failed:
                if best == nil { best = result }
            case .read, .partial:
                result.diagnostics = carried + result.diagnostics
                return result
            }
        }
        if let best { return best }
        return .unsupported(carried)
    }

    public func read(url: URL, tools: ReaderTools) -> ClipMetadata {
        read(ClipFile(url: url, tools: tools))
    }
}
