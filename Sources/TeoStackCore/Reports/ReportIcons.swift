import Foundation

/// Icone vettoriali dei report: tutte disegnate qui, con forme e colori propri di TeoStackPro (rombi per le valutazioni, nastro per i
/// segnalibri, quadratini per le etichette, barre piene, disco e foglio piatti), in una sola tinta d'accento più grigi neutri.
enum ReportIcons {
    typealias Color = PDFWriter.Color

    /// Tinta d'accento dei report (blu notte).
    static let accent = Color(hex: 0x1D4E89)
    static let accentLight = Color(hex: 0xC9D6E8)
    static let track = Color(hex: 0xE3E6EA)
    static let outline = Color(hex: 0x9AA3AE)

    /// Valutazione: rombo pieno (assegnato) o vuoto.
    static func ratingMark(_ pdf: PDFWriter, cx: Double, cy: Double, radius r: Double, filled: Bool) {
        let pts = [(cx, cy - r), (cx + r * 0.82, cy), (cx, cy + r), (cx - r * 0.82, cy)]
        if filled { pdf.polygon(pts, fillColor: accent) } else { pdf.polygon(pts, strokeColor: outline, lineWidth: 0.7) }
    }

    /// Segnalibro (clip contrassegnato): nastro con la tacca in basso.
    static func flagRibbon(_ pdf: PDFWriter, x: Double, y: Double, height: Double, filled: Bool = false) {
        let w = height * 0.62
        let pts = [(x, y), (x + w, y), (x + w, y + height), (x + w / 2, y + height * 0.74), (x, y + height)]
        if filled { pdf.polygon(pts, fillColor: accent) } else { pdf.polygon(pts, strokeColor: outline, lineWidth: 0.8) }
    }

    /// Etichetta colore: quadratino arrotondato (vuoto = «No Label»).
    static func labelSwatch(_ pdf: PDFWriter, x: Double, cy: Double, size: Double, color: Color? = nil) {
        if let color {
            pdf.fillRoundedRect(x: x, y: cy - size / 2, width: size, height: size, radius: size * 0.28, color: color)
        } else {
            pdf.strokeRoundedRect(x: x + 0.4, y: cy - size / 2 + 0.4, width: size - 0.8, height: size - 0.8, radius: size * 0.28, lineWidth: 0.8, color: outline)
        }
    }

    /// Barra di quota: pista chiara senza bordo e riempimento nella tinta d'accento.
    static func shareBar(_ pdf: PDFWriter, x: Double, y: Double, width: Double, height: Double, share: Double) {
        pdf.fillRoundedRect(x: x, y: y, width: width, height: height, radius: height / 2, color: track)
        let filled = width * max(0, min(1, share))
        if filled > 0.5 { pdf.fillRoundedRect(x: x, y: y, width: max(filled, height), height: height, radius: height / 2, color: accent) }
    }

    /// Cartella (riga di raggruppamento del Volume Report): linguetta e corpo.
    static func folderMark(_ pdf: PDFWriter, x: Double, y: Double) {
        pdf.fillRoundedRect(x: x, y: y, width: 3.4, height: 2.2, radius: 0.7, color: outline)
        pdf.fillRoundedRect(x: x, y: y + 1.5, width: 8.2, height: 5.6, radius: 1.0, color: outline)
    }

    /// Foglio piatto con tre righe di testo (file che non sono clip): angoli arrotondati, nessuna piega.
    static func document(_ pdf: PDFWriter, x: Double, y: Double, size: Double) {
        let s = size / 92.8
        let w = 58.0 * s, h = 76.0 * s, left = x + (size - w) / 2, top = y + 8 * s
        pdf.fillRoundedRect(x: left, y: top, width: w, height: h, radius: 6 * s, color: track)
        pdf.fillRoundedRect(x: left + 1.2 * s, y: top + 1.2 * s, width: w - 2.4 * s, height: h - 2.4 * s, radius: 5 * s, color: Color(hex: 0xFAFBFC))
        for (i, factor) in [0.7, 0.7, 0.45].enumerated() {
            pdf.fillRoundedRect(x: left + 10 * s, y: top + (18 + Double(i) * 15) * s, width: (w - 20 * s) * factor, height: 4.2 * s, radius: 2.1 * s, color: accentLight)
        }
    }

    /// Disco esterno piatto: corpo blu notte, faccia chiara e spia verde.
    static func drive(_ pdf: PDFWriter, x: Double, y: Double, size: Double) {
        let s = size / 53.6
        func X(_ v: Double) -> Double { x + v * s }
        func Y(_ v: Double) -> Double { y + v * s }
        pdf.fillRoundedRect(x: X(4), y: Y(8), width: 46 * s, height: 38 * s, radius: 7 * s, color: accent)
        pdf.fillRoundedRect(x: X(8), y: Y(12), width: 38 * s, height: 16 * s, radius: 4 * s, color: accentLight)
        pdf.fillRoundedRect(x: X(11), y: Y(34), width: 20 * s, height: 3.6 * s, radius: 1.8 * s, color: Color(hex: 0x6F8DB8))
        pdf.fillRoundedRect(x: X(39), y: Y(33.6), width: 5 * s, height: 5 * s, radius: 1.4 * s, color: Color(hex: 0x3FBF7F))
    }
}
