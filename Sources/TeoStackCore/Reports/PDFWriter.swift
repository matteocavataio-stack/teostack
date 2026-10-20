import Foundation

/// Scrittore PDF minimale, senza dipendenze, per i report.
/// - Coordinate in punti con l'origine in ALTO a sinistra (y cresce verso il basso), come nelle misure dei report di riferimento.
/// - Pagine di dimensione diversa nello stesso documento.
/// - Font: Helvetica (intestazioni) e DejaVu Sans Mono incorporato (corpo), testo WinAnsi con accenti italiani.
/// - Immagini JPEG (anteprime), rettangoli, rettangoli arrotondati, poligoni.
final class PDFWriter {
    enum Font {
        case sans, sansBold, mono, monoBold, monoItalic

        var resourceName: String {
            switch self {
            case .sans: return "F1"
            case .sansBold: return "F2"
            case .mono: return "F3"
            case .monoBold: return "F4"
            case .monoItalic: return "F5"
            }
        }

        var isMono: Bool { self == .mono || self == .monoBold || self == .monoItalic }

        /// Distanza dal bordo alto del testo alla linea di base, in frazioni del corpo (metriche di SF e Menlo dei riferimenti).
        var ascent: Double { isMono ? 0.9282 : 0.9526 }
    }

    struct Color {
        var r: Double, g: Double, b: Double
        init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
        init(hex: UInt32) {
            r = Double((hex >> 16) & 0xFF) / 255
            g = Double((hex >> 8) & 0xFF) / 255
            b = Double(hex & 0xFF) / 255
        }
        static let black = Color(hex: 0x000000)
        static let white = Color(hex: 0xFFFFFF)
        static let gray = Color(hex: 0x666666)        // testo secondario
        static let line = Color(hex: 0x696969)        // bordi e barre
        static let zebra = Color(hex: 0xEEEEEE)       // righe alterne e intestazioni
    }

    enum Align { case left, right, center }

    final class Page {
        let width: Double
        let height: Double
        fileprivate(set) var content = ""
        fileprivate var usedImages: Set<Int> = []
        init(width: Double, height: Double) { self.width = width; self.height = height }
    }

    private(set) var pages: [Page] = []
    private var images: [(info: JPEGInfo, data: Data)] = []
    private(set) var current: Page

    init(width: Double, height: Double) {
        current = Page(width: width, height: height)
        pages = [current]
    }

    func newPage(width: Double? = nil, height: Double? = nil) {
        current = Page(width: width ?? current.width, height: height ?? current.height)
        pages.append(current)
    }

    func select(page index: Int) { current = pages[index] }

    // MARK: Codifica del testo (WinAnsi)

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

    static let monoAdvance = 1233.0 / 2048.0      // larghezza dei caratteri di DejaVu Sans Mono / Menlo (em)

    static func width(_ s: String, size: Double, font: Font) -> Double {
        if font.isMono { return Double(winAnsi(s).count) * monoAdvance * size }
        let bold = font == .sansBold
        return Double(winAnsi(s).reduce(0) { $0 + HelveticaMetrics.width(of: $1, bold: bold) }) * size / 1000
    }

    // MARK: Disegno

    private func f(_ v: Double) -> String { String(format: "%.2f", v) }
    private func fill(_ c: Color) -> String { "\(f(c.r)) \(f(c.g)) \(f(c.b)) rg\n" }
    private func stroke(_ c: Color) -> String { "\(f(c.r)) \(f(c.g)) \(f(c.b)) RG\n" }
    private func py(_ y: Double) -> Double { current.height - y }

    func fillRect(x: Double, y: Double, width: Double, height: Double, color: Color) {
        guard width > 0, height > 0 else { return }
        current.content += fill(color) + "\(f(x)) \(f(py(y + height))) \(f(width)) \(f(height)) re f\n"
    }

    private func roundedPath(x: Double, y: Double, width: Double, height: Double, radius: Double) -> String {
        let r = min(radius, width / 2, height / 2), k = 0.5523 * r
        let x0 = x, x1 = x + width, y0 = py(y + height), y1 = py(y)
        return "\(f(x0 + r)) \(f(y0)) m \(f(x1 - r)) \(f(y0)) l \(f(x1 - r + k)) \(f(y0)) \(f(x1)) \(f(y0 + r - k)) \(f(x1)) \(f(y0 + r)) c "
            + "\(f(x1)) \(f(y1 - r)) l \(f(x1)) \(f(y1 - r + k)) \(f(x1 - r + k)) \(f(y1)) \(f(x1 - r)) \(f(y1)) c "
            + "\(f(x0 + r)) \(f(y1)) l \(f(x0 + r - k)) \(f(y1)) \(f(x0)) \(f(y1 - r + k)) \(f(x0)) \(f(y1 - r)) c "
            + "\(f(x0)) \(f(y0 + r)) l \(f(x0)) \(f(y0 + r - k)) \(f(x0 + r - k)) \(f(y0)) \(f(x0 + r)) \(f(y0)) c h\n"
    }

    /// Bordo (centrato sul perimetro indicato) di un rettangolo arrotondato.
    func strokeRoundedRect(x: Double, y: Double, width: Double, height: Double, radius: Double, lineWidth: Double, color: Color) {
        current.content += stroke(color) + "\(f(lineWidth)) w\n" + roundedPath(x: x, y: y, width: width, height: height, radius: radius) + "S\n"
    }

    func fillRoundedRect(x: Double, y: Double, width: Double, height: Double, radius: Double, color: Color) {
        guard width > 0, height > 0 else { return }
        current.content += fill(color) + roundedPath(x: x, y: y, width: width, height: height, radius: radius) + "f\n"
    }

    func polygon(_ points: [(Double, Double)], fillColor: Color? = nil, strokeColor: Color? = nil, lineWidth: Double = 0.6) {
        guard let first = points.first else { return }
        var path = "\(f(first.0)) \(f(py(first.1))) m "
        for p in points.dropFirst() { path += "\(f(p.0)) \(f(py(p.1))) l " }
        path += "h\n"
        var op = ""
        if let c = fillColor { op += fill(c) }
        if let c = strokeColor { op += stroke(c) + "\(f(lineWidth)) w\n" }
        let paint = fillColor != nil && strokeColor != nil ? "B" : (fillColor != nil ? "f" : "S")
        current.content += op + path + paint + "\n"
    }

    /// Cerchio (bordo e/o riempimento) con centro (cx, cy).
    func circle(cx: Double, cy: Double, radius: Double, fillColor: Color? = nil, strokeColor: Color? = nil, lineWidth: Double = 0.7) {
        let k = 0.5523 * radius, x = cx, y = py(cy)
        let path = "\(f(x + radius)) \(f(y)) m \(f(x + radius)) \(f(y + k)) \(f(x + k)) \(f(y + radius)) \(f(x)) \(f(y + radius)) c "
            + "\(f(x - k)) \(f(y + radius)) \(f(x - radius)) \(f(y + k)) \(f(x - radius)) \(f(y)) c "
            + "\(f(x - radius)) \(f(y - k)) \(f(x - k)) \(f(y - radius)) \(f(x)) \(f(y - radius)) c "
            + "\(f(x + k)) \(f(y - radius)) \(f(x + radius)) \(f(y - k)) \(f(x + radius)) \(f(y)) c h\n"
        var op = ""
        if let c = fillColor { op += fill(c) }
        if let c = strokeColor { op += stroke(c) + "\(f(lineWidth)) w\n" }
        let paint = fillColor != nil && strokeColor != nil ? "B" : (fillColor != nil ? "f" : "S")
        current.content += op + path + paint + "\n"
    }

    func line(x1: Double, y1: Double, x2: Double, y2: Double, color: Color, width: Double = 0.5) {
        current.content += stroke(color) + "\(f(width)) w \(f(x1)) \(f(py(y1))) m \(f(x2)) \(f(py(y2))) l S\n"
    }

    /// Testo con il bordo ALTO del riquadro del carattere in `top` (come le misure dei riferimenti).
    func text(_ s: String, x: Double, top: Double, size: Double, font: Font, color: Color = .black,
              align: Align = .left, width: Double? = nil) {
        guard !s.isEmpty else { return }
        let w = PDFWriter.width(s, size: size, font: font)
        var tx = x
        switch align {
        case .left: break
        case .right: tx = x + (width ?? 0) - w
        case .center: tx = x + ((width ?? 0) - w) / 2
        }
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
        let baseline = top + font.ascent * size
        current.content += "BT\n\(fill(color))/\(font.resourceName) \(f(size)) Tf\n\(f(tx)) \(f(py(baseline))) Td\n\(literal) Tj\nET\n"
    }

    /// Registra un JPEG e restituisce il suo indice per `image(_:x:y:width:height:)`.
    func addJPEG(_ data: Data) -> Int? {
        guard let info = JPEGInfo.parse(data) else { return nil }
        images.append((info, data))
        return images.count - 1
    }

    func image(_ index: Int, x: Double, y: Double, width: Double, height: Double) {
        current.usedImages.insert(index)
        current.content += "q \(f(width)) 0 0 \(f(height)) \(f(x)) \(f(py(y + height))) cm /Im\(index) Do Q\n"
    }

    func imageSize(_ index: Int) -> (width: Int, height: Int) { (images[index].info.width, images[index].info.height) }

    // MARK: Serializzazione

    func data(title: String, author: String? = nil, creator: String = "TeoStackXt") -> Data {
        var out = Data("%PDF-1.4\n%\u{E2}\u{E3}\u{CF}\u{D3}\n".utf8)
        var offsets: [Int] = []
        @discardableResult func add(_ body: Data) -> Int {
            offsets.append(out.count)
            out += Data("\(offsets.count) 0 obj\n".utf8) + body + Data("\nendobj\n".utf8)
            return offsets.count
        }
        func str(_ s: String) -> Data { Data(s.utf8) }
        func stream(_ dict: String, _ bytes: Data) -> Data {
            str("<< \(dict) /Length \(bytes.count) >>\nstream\n") + bytes + str("\nendstream")
        }

        // Oggetti fissi: 1 Catalog, 2 Pages, 3-4 Helvetica, 5-7 descrittori mono, 8-10 file font, 11-13 font mono, 14 Info
        let monoFiles: [(name: String, data: Data, bold: Bool, italic: Bool)] = [
            ("DejaVuSansMono", ReportFontData.regular, false, false),
            ("DejaVuSansMono-Bold", ReportFontData.bold, true, false),
            ("DejaVuSansMono-Oblique", ReportFontData.oblique, false, true),
        ]
        let firstPageObject = 15 + images.count
        let kids = pages.indices.map { "\(firstPageObject + $0 * 2) 0 R" }.joined(separator: " ")
        add(str("<< /Type /Catalog /Pages 2 0 R >>"))                                                                    // 1
        add(str("<< /Type /Pages /Kids [\(kids)] /Count \(pages.count) >>"))                                            // 2
        add(str("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"))                    // 3
        add(str("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>"))               // 4
        for (i, m) in monoFiles.enumerated() {                                                                           // 5-7
            let flags = 33 | (m.italic ? 64 : 0)
            add(str("<< /Type /FontDescriptor /FontName /\(m.name) /Flags \(flags) /FontBBox [-559 -375 718 1028] /ItalicAngle \(m.italic ? -11 : 0) "
                    + "/Ascent 928 /Descent -236 /CapHeight 729 /StemV \(m.bold ? 140 : 80) /FontFile2 \(8 + i) 0 R >>"))
        }
        for m in monoFiles { add(stream("/Length1 \(m.data.count)", m.data)) }                                          // 8-10
        let widths = Array(repeating: "602", count: 224).joined(separator: " ")
        for (i, m) in monoFiles.enumerated() {                                                                           // 11-13
            add(str("<< /Type /Font /Subtype /TrueType /BaseFont /\(m.name) /FirstChar 32 /LastChar 255 /Widths [\(widths)] "
                    + "/Encoding /WinAnsiEncoding /FontDescriptor \(5 + i) 0 R >>"))
        }
        var info = "<< /Title \(PDFWriter.pdfString(title)) /Creator \(PDFWriter.pdfString(creator))"
        if let author, !author.isEmpty { info += " /Author \(PDFWriter.pdfString(author))" }
        add(str(info + " >>"))                                                                                           // 14
        for img in images {                                                                                              // 15...
            let cs = img.info.components == 1 ? "/DeviceGray" : "/DeviceRGB"
            add(stream("/Type /XObject /Subtype /Image /Width \(img.info.width) /Height \(img.info.height) /ColorSpace \(cs) /BitsPerComponent 8 /Filter /DCTDecode", img.data))
        }
        for (i, page) in pages.enumerated() {
            let contentObject = firstPageObject + i * 2 + 1
            let xobjects = page.usedImages.sorted().map { "/Im\($0) \(15 + $0) 0 R" }.joined(separator: " ")
            let resources = "/Font << /F1 3 0 R /F2 4 0 R /F3 11 0 R /F4 12 0 R /F5 13 0 R >>"
                + (xobjects.isEmpty ? "" : " /XObject << \(xobjects) >>")
            add(str("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(f(page.width)) \(f(page.height))] /Resources << \(resources) >> /Contents \(contentObject) 0 R >>"))
            add(stream("", Data(page.content.utf8)))
        }

        let xrefPosition = out.count
        var xref = "xref\n0 \(offsets.count + 1)\n0000000000 65535 f \n"
        for o in offsets { xref += String(format: "%010d 00000 n \n", o) }
        xref += "trailer\n<< /Size \(offsets.count + 1) /Root 1 0 R /Info 14 0 R >>\nstartxref\n\(xrefPosition)\n%%EOF\n"
        out += str(xref)
        return out
    }

    static func pdfString(_ s: String) -> String {
        var hex = "FEFF"
        for u in s.utf16 { hex += String(format: "%04X", u) }
        return "<\(hex)>"
    }
}

/// Dimensioni e componenti di un JPEG (marcatore SOF).
struct JPEGInfo {
    var width: Int
    var height: Int
    var components: Int

    static func parse(_ data: Data) -> JPEGInfo? {
        let b = [UInt8](data)
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var i = 2
        while i + 9 < b.count {
            guard b[i] == 0xFF else { i += 1; continue }
            let marker = b[i + 1]
            if marker == 0xFF { i += 1; continue }
            if [0xC0, 0xC1, 0xC2].contains(marker) {
                let components = Int(b[i + 9])
                guard components == 1 || components == 3, b[i + 4] == 8 else { return nil }   // solo 8 bit, grigio o RGB/YCbCr
                return JPEGInfo(width: Int(b[i + 7]) << 8 | Int(b[i + 8]), height: Int(b[i + 5]) << 8 | Int(b[i + 6]), components: components)
            }
            if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) { i += 2; continue }
            i += 2 + (Int(b[i + 2]) << 8 | Int(b[i + 3]))
        }
        return nil
    }
}
