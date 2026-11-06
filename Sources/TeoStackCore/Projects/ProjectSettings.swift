import Foundation

/// Impostazioni di UN progetto: opzioni dell'offload e i due loghi (PROGETTO a sinistra, SERVICE a destra) stampati in testa a ogni report.
public struct ProjectSettings: Equatable {
    /// «Verifica durante la copia»: ogni file viene riletto appena scritto, mentre la copia prosegue.
    public var overlapVerification: Bool
    /// «Crea certificato ASC MHL» a offload riuscito.
    public var ascMHL: Bool
    /// «Svuota la sorgente a fine offload»: a offload riuscito la parte «Sorgente» dell'app si svuota (non si cancella nulla dalla scheda).
    public var clearSourceWhenDone: Bool
    /// Logo PROGETTO (JPEG), in alto a sinistra in ogni report.
    public var projectLogo: Data?
    /// Logo SERVICE (JPEG), in alto a destra in ogni report.
    public var serviceLogo: Data?

    public static let maxLogoBytes = 4 * 1024 * 1024

    public init(overlapVerification: Bool = true, ascMHL: Bool = true, clearSourceWhenDone: Bool = true,
                projectLogo: Data? = nil, serviceLogo: Data? = nil) {
        self.overlapVerification = overlapVerification
        self.ascMHL = ascMHL
        self.clearSourceWhenDone = clearSourceWhenDone
        self.projectLogo = projectLogo
        self.serviceLogo = serviceLogo
    }

    /// Un logo deve essere un JPEG (grigio o colore, 8 bit) e non superare `maxLogoBytes`: l'app converte da sola le immagini scelte (PNG, TIFF, PDF…).
    public static func validateLogo(_ data: Data) throws {
        guard data.count <= maxLogoBytes else {
            throw ProjectStoreError.invalidOperation(tr("L'immagine è troppo grande (massimo {0}).", Format.bytes(Int64(maxLogoBytes))))
        }
        guard JPEGInfo.parse(data) != nil else {
            throw ProjectStoreError.invalidOperation(tr("L'immagine non è un JPEG leggibile (grigio o colore a 8 bit)."))
        }
    }

    /// Dimensioni in pixel di un logo JPEG (nil se non è leggibile).
    public static func logoSize(_ data: Data) -> (width: Int, height: Int)? {
        JPEGInfo.parse(data).map { ($0.width, $0.height) }
    }
}
