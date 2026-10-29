import Foundation

/// Blocchi del manuale. Nei testi, «**parola**» = grassetto.
enum ManualBlock {
    case h1(String)
    case h2(String)
    case p(String)
    case bullets([String])
    case steps([String])
    case note(String)
    case warning(String)
    case code([String])
    case table(header: [String], rows: [[String]], widths: [Double])
}

/// Costruisce il manuale utente in PDF (A4) con copertina, indice con numeri di pagina, titoli, elenchi, tabelle e numeri di pagina.
/// Usa lo scrittore PDF dei report: Helvetica per il testo, DejaVu Sans Mono incorporato per comandi e codice.
public enum ManualPDF {
    public static let fileName = fileName(for: .italian)

    /// Nome del file nella lingua del manuale.
    public static func fileName(for language: AppLanguage) -> String {
        language == .italian ? "TeoStackPro-Manuale.pdf" : "TeoStackPro-Manual.pdf"
    }

    /// Il manuale nella lingua dell'app (o in quella indicata).
    public static func render(language: AppLanguage = Loc.language, version: String = AppInfo.version, date: Date = Date()) -> Data {
        ManualLayout(blocks: ManualContent.blocks(for: language), labels: ManualLabels(language), version: version, date: date).render()
    }

    /// Numero di sezioni e sottosezioni (per i test).
    static func headingCount(for language: AppLanguage = .italian) -> Int {
        ManualContent.blocks(for: language).filter { if case .h1 = $0 { return true }; if case .h2 = $0 { return true }; return false }.count
    }
}

/// Testi fissi del manuale (copertina, indice, riquadri, piè di pagina) nelle quattro lingue.
struct ManualLabels {
    let title, tagline, version, languages, contents, note, warning, footer: String
    let locale: Locale

    init(_ language: AppLanguage) {
        switch language {
        case .italian:
            title = "Manuale utente"; tagline = "Copia verificata, metadata e report per il DIT"; version = "Versione"
            languages = "Per macOS · lingue dell'app: Italiano, English, Castellano, Català"
            contents = "Indice"; note = "Nota"; warning = "Attenzione"
        case .english:
            title = "User manual"; tagline = "Verified copies, metadata and reports for the DIT"; version = "Version"
            languages = "For macOS · app languages: Italiano, English, Castellano, Català"
            contents = "Contents"; note = "Note"; warning = "Warning"
        case .spanish:
            title = "Manual de usuario"; tagline = "Copia verificada, metadatos e informes para el DIT"; version = "Versión"
            languages = "Para macOS · idiomas de la app: Italiano, English, Castellano, Català"
            contents = "Índice"; note = "Nota"; warning = "Atención"
        case .catalan:
            title = "Manual d'usuari"; tagline = "Còpia verificada, metadades i informes per al DIT"; version = "Versió"
            languages = "Per a macOS · idiomes de l'app: Italiano, English, Castellano, Català"
            contents = "Índex"; note = "Nota"; warning = "Atenció"
        }
        footer = "TeoStackPro · \(title)"
        locale = Locale(identifier: ["it": "it_IT", "en": "en_GB", "es": "es_ES", "ca": "ca_ES"][language.rawValue] ?? "it_IT")
    }
}

private final class ManualLayout {
    typealias Font = PDFWriter.Font

    let blocks: [ManualBlock]
    let labels: ManualLabels
    let version: String
    let date: Date

    // pagina A4 in punti
    let pageW = 595.276, pageH = 841.89
    let left = 56.0, right = 56.0, top = 70.0, bottom = 62.0
    var contentW: Double { pageW - left - right }
    let bodySize = 10.2, lineH = 14.2
    let tocTop = 56.0, tocLine = 13.6

    let pdf = PDFWriter(width: 595.276, height: 841.89)
    var y = 0.0
    var pageNumber = 1                      // pagina fisica corrente (1 = copertina)
    var toc: [(level: Int, title: String, page: Int)] = []
    var tocPages: [Int] = []                // indici (0-based) delle pagine riservate all'indice

    init(blocks: [ManualBlock], labels: ManualLabels, version: String, date: Date) {
        self.blocks = blocks
        self.labels = labels
        self.version = version
        self.date = date
    }

    // MARK: Regia

    func render() -> Data {
        drawCover()
        // pagine riservate all'indice: le voci sono note in anticipo (ogni titolo di livello 1 e 2)
        let entries = blocks.filter { if case .h1 = $0 { return true }; if case .h2 = $0 { return true }; return false }.count
        let firstCapacity = Int((pageH - tocTop - bottom - 30) / tocLine)
        let otherCapacity = Int((pageH - tocTop - bottom) / tocLine)
        let tocPageCount = entries <= firstCapacity ? 1 : 1 + Int((Double(entries - firstCapacity) / Double(otherCapacity)).rounded(.up))
        let perPage = firstCapacity
        for _ in 0 ..< tocPageCount { newPage(); tocPages.append(pdf.pages.count - 1) }
        newPage()
        for block in blocks { draw(block) }
        drawTOC(perPage: perPage)
        addFooters()
        return pdf.data(title: "TeoStackPro - \(labels.title)", author: nil)
    }

    func newPage() {
        pdf.newPage()
        pageNumber = pdf.pages.count
        y = top
    }

    func ensure(_ height: Double) {
        if y + height > pageH - bottom { newPage() }
    }

    // MARK: Copertina e indice

    func drawCover() {
        pdf.fillRect(x: 0, y: 0, width: pageW, height: 18, color: PDFWriter.Color(hex: 0x1D4E89))
        pdf.text("TeoStackPro", x: left, top: 250, size: 44, font: .sansBold, color: PDFWriter.Color(hex: 0x1D4E89))
        pdf.text(labels.title, x: left, top: 306, size: 24, font: .sans)
        pdf.line(x1: left, y1: 346, x2: left + 150, y2: 346, color: PDFWriter.Color(hex: 0x1D4E89), width: 2)
        pdf.text(labels.tagline, x: left, top: 362, size: 13, font: .sans, color: .gray)
        let f = DateFormatter()
        f.locale = labels.locale
        f.dateStyle = .long
        f.timeStyle = .none
        pdf.text("\(labels.version) \(version) · \(f.string(from: date))", x: left, top: 392, size: 11, font: .sans, color: .gray)
        pdf.text(labels.languages, x: left, top: pageH - 70, size: 9.5, font: .sans, color: .gray)
    }

    func drawTOC(perPage: Int) {
        var index = 0
        for (n, pageIndex) in tocPages.enumerated() {
            pdf.select(page: pageIndex)
            var ty = tocTop
            if n == 0 {
                pdf.text(labels.contents, x: left, top: ty, size: 20, font: .sansBold, color: PDFWriter.Color(hex: 0x1D4E89))
                ty += 30
            }
            while ty + tocLine < pageH - bottom, index < toc.count {
                let e = toc[index]
                let x = left + (e.level == 2 ? 16 : 0)
                let font: Font = e.level == 1 ? .sansBold : .sans
                let size = e.level == 1 ? 10.2 : 9.4
                pdf.text(e.title, x: x, top: ty, size: size, font: font)
                pdf.text(String(e.page), x: pageW - right - 40, top: ty, size: size, font: font, align: .right, width: 40)
                ty += tocLine
                index += 1
            }
        }
        pdf.select(page: pdf.pages.count - 1)
    }

    func addFooters() {
        for i in 1 ..< pdf.pages.count {
            pdf.select(page: i)
            pdf.line(x1: left, y1: pageH - 46, x2: pageW - right, y2: pageH - 46, color: PDFWriter.Color(hex: 0xBBBBBB), width: 0.5)
            pdf.text(labels.footer, x: left, top: pageH - 38, size: 8.5, font: .sans, color: .gray)
            pdf.text(String(i + 1), x: pageW - right - 40, top: pageH - 38, size: 8.5, font: .sans, color: .gray, align: .right, width: 40)
        }
        pdf.select(page: pdf.pages.count - 1)
    }

    // MARK: Blocchi

    func draw(_ block: ManualBlock) {
        switch block {
        case .h1(let t):
            ensure(170)   // titolo + primo sottotitolo + qualche riga: mai un titolo solo in fondo alla pagina
            if y > top + 1 { y += 10 }
            toc.append((1, t, pageNumber))
            pdf.text(t, x: left, top: y, size: 17, font: .sansBold, color: PDFWriter.Color(hex: 0x1D4E89))
            y += 24
            pdf.line(x1: left, y1: y, x2: pageW - right, y2: y, color: PDFWriter.Color(hex: 0x1D4E89), width: 1)
            y += 12
        case .h2(let t):
            ensure(120)
            y += 6
            toc.append((2, t, pageNumber))
            pdf.text(t, x: left, top: y, size: 12.4, font: .sansBold)
            y += 20
        case .p(let t):
            paragraph(t, x: left, width: contentW)
            y += 5
        case .bullets(let items):
            for item in items { listItem(marker: "•", item) }
            y += 4
        case .steps(let items):
            for (i, item) in items.enumerated() { listItem(marker: "\(i + 1).", item) }
            y += 4
        case .note(let t): callout(t, label: labels.note, color: PDFWriter.Color(hex: 0x1D4E89), fill: PDFWriter.Color(hex: 0xEAF1FA))
        case .warning(let t): callout(t, label: labels.warning, color: PDFWriter.Color(hex: 0xB45309), fill: PDFWriter.Color(hex: 0xFFF4E0))
        case .code(let lines): code(lines)
        case .table(let header, let rows, let widths): table(header: header, rows: rows, widths: widths)
        }
    }

    // MARK: Testo con grassetto

    /// Parola con il suo font; `glue` = attaccata alla precedente (es. la virgola subito dopo un grassetto: niente spazio).
    typealias Token = (word: String, font: Font, glue: Bool)

    /// Parole con il loro font; «**…**» attiva il grassetto.
    func tokens(_ text: String, bold base: Bool = false) -> [Token] {
        var out: [Token] = []
        var bold = base
        var prevEndsWithSpace = true
        for (i, part) in text.components(separatedBy: "**").enumerated() {
            if i > 0 { bold.toggle() }
            if part.isEmpty { continue }
            let startsWithSpace = part.first == " "
            for (k, word) in part.split(separator: " ", omittingEmptySubsequences: true).enumerated() {
                let glue = k == 0 && !startsWithSpace && !prevEndsWithSpace && !out.isEmpty
                out.append((String(word), bold ? .sansBold : .sans, glue))
            }
            prevEndsWithSpace = part.last == " "
        }
        return out
    }

    func wrap(_ text: String, width: Double, size: Double, bold: Bool = false) -> [[Token]] {
        var lines: [[Token]] = [[]]
        var x = 0.0
        let space = PDFWriter.width(" ", size: size, font: .sans)
        for token in tokens(text, bold: bold) {
            let w = PDFWriter.width(token.word, size: size, font: token.font)
            if token.glue, !lines[lines.count - 1].isEmpty {
                lines[lines.count - 1].append(token)
                x += w
                continue
            }
            if x > 0 && x + space + w > width { lines.append([]); x = 0 }
            if x > 0 { x += space }
            lines[lines.count - 1].append(token)
            x += w
        }
        return lines
    }

    func drawLine(_ words: [Token], x: Double, top: Double, size: Double, color: PDFWriter.Color = .black) {
        var cx = x
        let space = PDFWriter.width(" ", size: size, font: .sans)
        for (i, token) in words.enumerated() {
            if i > 0 && !token.glue { cx += space }
            pdf.text(token.word, x: cx, top: top, size: size, font: token.font, color: color)
            cx += PDFWriter.width(token.word, size: size, font: token.font)
        }
    }

    func paragraph(_ text: String, x: Double, width: Double, size: Double? = nil, color: PDFWriter.Color = .black) {
        let s = size ?? bodySize
        for line in wrap(text, width: width, size: s) {
            ensure(lineH)
            drawLine(line, x: x, top: y, size: s, color: color)
            y += lineH * (s / bodySize)
        }
    }

    func listItem(marker: String, _ text: String) {
        let indent = 16.0
        let lines = wrap(text, width: contentW - indent - 4, size: bodySize)
        for (i, line) in lines.enumerated() {
            ensure(lineH)
            if i == 0 { pdf.text(marker, x: left + 2, top: y, size: bodySize, font: .sansBold, color: PDFWriter.Color(hex: 0x1D4E89)) }
            drawLine(line, x: left + indent + 4, top: y, size: bodySize)
            y += lineH
        }
        y += 2
    }

    func callout(_ text: String, label: String, color: PDFWriter.Color, fill: PDFWriter.Color) {
        let inner = contentW - 24
        let lines = wrap("**\(label):** " + text, width: inner, size: 9.8)
        let height = Double(lines.count) * 13.4 + 12
        ensure(min(height, 140))
        let boxTop = y
        let avail = pageH - bottom - boxTop
        if height <= avail {
            pdf.fillRect(x: left, y: boxTop, width: contentW, height: height, color: fill)
            pdf.fillRect(x: left, y: boxTop, width: 3, height: height, color: color)
            var ly = boxTop + 6
            for line in lines { drawLine(line, x: left + 14, top: ly, size: 9.8); ly += 13.4 }
            y = boxTop + height + 8
        } else {
            for line in lines { ensure(13.4); drawLine(line, x: left + 14, top: y, size: 9.8); y += 13.4 }
            y += 8
        }
    }

    func code(_ lines: [String]) {
        let size = 8.4, lh = 11.6
        let height = Double(lines.count) * lh + 10
        ensure(min(height, 120))
        let boxTop = y
        if boxTop + height <= pageH - bottom {
            pdf.fillRoundedRect(x: left, y: boxTop, width: contentW, height: height, radius: 3, color: PDFWriter.Color(hex: 0xF0F0F0))
            var ly = boxTop + 5
            for l in lines { pdf.text(l, x: left + 8, top: ly, size: size, font: .mono); ly += lh }
            y = boxTop + height + 8
        } else {
            for l in lines { ensure(lh); pdf.text(l, x: left + 8, top: y, size: size, font: .mono); y += lh }
            y += 8
        }
    }

    func table(header: [String], rows: [[String]], widths: [Double]) {
        let total = widths.reduce(0, +)
        let colW = widths.map { $0 / total * contentW }
        let size = 9.0, lh = 12.0, pad = 4.0
        func rowLines(_ cells: [String], bold: Bool) -> [[[Token]]] {
            cells.enumerated().map { wrap($0.element, width: colW[$0.offset] - 2 * pad, size: size, bold: bold) }
        }
        func drawRow(_ cells: [String], bold: Bool, fill: PDFWriter.Color?) {
            let cols = rowLines(cells, bold: bold)
            let n = cols.map(\.count).max() ?? 1
            let height = Double(n) * lh + 2 * pad - 2
            ensure(height)
            if let fill { pdf.fillRect(x: left, y: y, width: contentW, height: height, color: fill) }
            var cx = left
            for (i, lines) in cols.enumerated() {
                var ly = y + pad - 1
                for line in lines { drawLine(line, x: cx + pad, top: ly, size: size); ly += lh }
                cx += colW[i]
            }
            y += height
        }
        ensure(60)
        drawRow(header, bold: true, fill: PDFWriter.Color(hex: 0xD6E2F3))
        for (i, row) in rows.enumerated() {
            drawRow(row, bold: false, fill: i % 2 == 1 ? PDFWriter.Color.zebra : nil)
        }
        pdf.line(x1: left, y1: y, x2: pageW - right, y2: y, color: PDFWriter.Color(hex: 0xBBBBBB), width: 0.5)
        y += 10
    }
}
