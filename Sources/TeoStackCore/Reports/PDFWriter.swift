import Foundation

/// Scrittore PDF minimale (nessuna dipendenza): pagine, testo con font standard Helvetica / Helvetica-Bold (WinAnsi), rettangoli e linee.
/// Il testo può contenere lettere accentate italiane; i caratteri non rappresentabili diventano "?".
final class PDFWriter {
    static let pageWidth = 842.0     // A4 orizzontale
    static let pageHeight = 595.0

    struct Color {
        var r: Double, g: Double, b: Double
        static let black = Color(r: 0, g: 0, b: 0)
        static let white = Color(r: 1, g: 1, b: 1)
        static let gray = Color(r: 0.4, g: 0.4, b: 0.4)
        static let dark = Color(r: 0.17, g: 0.23, b: 0.29)
        static let light = Color(r: 0.89, g: 0.91, b: 0.93)
        static let zebra = Color(r: 0.965, g: 0.973, b: 0.98)
        static let red = Color(r: 0.75, g: 0.1, b: 0.1)
        static let green = Color(r: 0.1, g: 0.5, b: 0.2)
    }

    final class Page {
        fileprivate var content = ""
    }

    private(set) var pages: [Page] = []
    var current: Page

    init() {
        current = Page()
        pages = [current]
    }

    func newPage() {
        current = Page()
        pages.append(current)
    }

    // MARK: Codifica del testo

    private static let cp1252Extras: [UInt32: UInt8] = [
        0x20AC: 0x80, 0x201A: 0x82, 0x0192: 0x83, 0x201E: 0x84, 0x2026: 0x85, 0x2020: 0x86, 0x2021: 0x87, 0x02C6: 0x88,
        0x2030: 0x89, 0x0160: 0x8A, 0x2039: 0x8B, 0x0152: 0x8C, 0x017D: 0x8E, 0x2018: 0x91, 0x2019: 0x92, 0x201C: 0x93,
        0x201D: 0x94, 0x2022: 0x95, 0x2013: 0x96, 0x2014: 0x97, 0x02DC: 0x98, 0x2122: 0x99, 0x0161: 0x9A, 0x203A: 0x9B,
        0x0153: 0x9C, 0x017E: 0x9E, 0x0178: 0x9F,
    ]

    static func winAnsi(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        for u in s.unicodeScalars {
            switch u.value {
            case 0x20...0x7E, 0xA0...0xFF: out.append(UInt8(u.value))
            case 0x09, 0x0A, 0x0D: out.append(0x20)
            default: out.append(PDFWriter.cp1252Extras[u.value] ?? 0x3F)
            }
        }
        return out
    }

    static func width(_ s: String, size: Double, bold: Bool) -> Double {
        Double(winAnsi(s).reduce(0) { $0 + HelveticaMetrics.width(of: $1, bold: bold) }) * size / 1000
    }

    // MARK: Disegno (y in coordinate PDF: 0 = fondo pagina)

    private func fmt(_ v: Double) -> String { String(format: "%.2f", v) }

    private func setFill(_ c: Color) -> String { "\(fmt(c.r)) \(fmt(c.g)) \(fmt(c.b)) rg\n" }

    func fillRect(x: Double, y: Double, width: Double, height: Double, color: Color) {
        current.content += setFill(color) + "\(fmt(x)) \(fmt(y)) \(fmt(width)) \(fmt(height)) re f\n"
    }

    func line(x1: Double, y1: Double, x2: Double, y2: Double, color: Color, width: Double = 0.5) {
        current.content += "\(fmt(color.r)) \(fmt(color.g)) \(fmt(color.b)) RG \(fmt(width)) w \(fmt(x1)) \(fmt(y1)) m \(fmt(x2)) \(fmt(y2)) l S\n"
    }

    func text(_ s: String, x: Double, y: Double, size: Double, bold: Bool = false, color: Color = .black) {
        var literal = "("
        for b in PDFWriter.winAnsi(s) {
            switch b {
            case 0x28: literal += "\\("
            case 0x29: literal += "\\)"
            case 0x5C: literal += "\\\\"
            case 0x20...0x7E: literal += String(UnicodeScalar(b))
            default: literal += String(format: "\\%03o", b)
            }
        }
        literal += ")"
        current.content += "BT\n\(setFill(color))/\(bold ? "F2" : "F1") \(fmt(size)) Tf\n\(fmt(x)) \(fmt(y)) Td\n\(literal) Tj\nET\n"
    }

    // MARK: Serializzazione

    func data(title: String, author: String? = nil, creator: String = "TeoStackXt") -> Data {
        var out = Data("%PDF-1.4\n%\u{E2}\u{E3}\u{CF}\u{D3}\n".utf8)
        var offsets: [Int] = []          // offsets[i] = posizione dell'oggetto numero i+1

        func addObject(_ body: Data) {
            offsets.append(out.count)
            out += Data("\(offsets.count) 0 obj\n".utf8) + body + Data("\nendobj\n".utf8)
        }
        func str(_ s: String) -> Data { Data(s.utf8) }

        // 1 Catalog, 2 Pages, 3 F1, 4 F2, 5 Info, poi per ogni pagina: Page e Content
        let firstPageObject = 6
        let kids = pages.indices.map { "\(firstPageObject + $0 * 2) 0 R" }.joined(separator: " ")
        addObject(str("<< /Type /Catalog /Pages 2 0 R >>"))
        addObject(str("<< /Type /Pages /Kids [\(kids)] /Count \(pages.count) >>"))
        addObject(str("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"))
        addObject(str("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>"))
        var info = "<< /Title \(PDFWriter.pdfString(title)) /Creator \(PDFWriter.pdfString(creator))"
        if let author, !author.isEmpty { info += " /Author \(PDFWriter.pdfString(author))" }
        addObject(str(info + " >>"))
        for (i, page) in pages.enumerated() {
            let contentObject = firstPageObject + i * 2 + 1
            addObject(str("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(Int(PDFWriter.pageWidth)) \(Int(PDFWriter.pageHeight))] /Resources << /Font << /F1 3 0 R /F2 4 0 R >> >> /Contents \(contentObject) 0 R >>"))
            let stream = Data(page.content.utf8)
            addObject(str("<< /Length \(stream.count) >>\nstream\n") + stream + str("\nendstream"))
        }

        let xrefPosition = out.count
        var xref = "xref\n0 \(offsets.count + 1)\n0000000000 65535 f \n"
        for o in offsets { xref += String(format: "%010d 00000 n \n", o) }
        xref += "trailer\n<< /Size \(offsets.count + 1) /Root 1 0 R /Info 5 0 R >>\nstartxref\n\(xrefPosition)\n%%EOF\n"
        out += str(xref)
        return out
    }

    /// Stringa PDF in UTF-16BE con BOM (valida per qualunque carattere).
    static func pdfString(_ s: String) -> String {
        var hex = "FEFF"
        for u in s.utf16 { hex += String(format: "%04X", u) }
        return "<\(hex)>"
    }
}
