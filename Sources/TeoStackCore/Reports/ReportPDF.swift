import Foundation

/// Impaginazione del documento del report in PDF (A4 orizzontale, template "Classic").
public enum ReportPDF {
    private static let margin = 36.0
    private static let top = 42.0
    private static let bottom = 46.0
    private static let usableWidth = PDFWriter.pageWidth - 2 * margin

    public static func render(_ doc: ReportDocument, generatedAt: Date = Date()) -> Data {
        let w = PDFWriter()
        var y = top                         // distanza dal bordo alto
        func pdfY(_ fromTop: Double) -> Double { PDFWriter.pageHeight - fromTop }
        func ensureSpace(_ height: Double) {
            if y + height > PDFWriter.pageHeight - bottom { w.newPage(); y = top }
        }

        // Intestazione
        w.text(doc.title, x: margin, y: pdfY(y + 18), size: 20, bold: true, color: .dark)
        w.text("Template \(doc.template)", x: margin, y: pdfY(y + 32), size: 8, color: .gray)
        y += 46
        for (k, v) in doc.meta {
            w.text(k, x: margin, y: pdfY(y + 9), size: 9, color: .gray)
            for (i, line) in wrap(v, width: usableWidth - 120, size: 9, bold: false, maxLines: 3).enumerated() {
                w.text(line, x: margin + 120, y: pdfY(y + 9 + Double(i) * 11), size: 9, bold: true)
            }
            y += 12 + Double(max(0, wrap(v, width: usableWidth - 120, size: 9, bold: false, maxLines: 3).count - 1)) * 11
        }
        y += 10

        for block in doc.blocks {
            let needed: Double
            switch block.content {
            case .table: needed = 18 + 14 + 20 + 22    // barra + sottotitolo + intestazione + una riga
            case .keyValues(let items):                 // i riepiloghi brevi restano sulla stessa pagina
                let height = 22 + items.reduce(0.0) { $0 + Double(wrap($1.1, width: usableWidth - 190, size: 9, bold: false, maxLines: 4).count) * 11 + 2 }
                needed = min(height, PDFWriter.pageHeight - top - bottom)
            default: needed = 18 + 30
            }
            ensureSpace(needed)
            w.fillRect(x: margin, y: pdfY(y + 16), width: usableWidth, height: 16, color: .dark)
            w.text(block.title, x: margin + 6, y: pdfY(y + 11.5), size: 10.5, bold: true, color: .white)
            y += 20
            if let sub = block.subtitle {
                for line in wrap(sub, width: usableWidth, size: 8, bold: false, maxLines: 2) {
                    w.text(line, x: margin, y: pdfY(y + 8), size: 8, color: .gray)
                    y += 10
                }
                y += 2
            }

            switch block.content {
            case .text(let t):
                for paragraph in t.components(separatedBy: "\n") {
                    for line in wrap(paragraph, width: usableWidth, size: 9, bold: false, maxLines: 10_000) {
                        ensureSpace(12)
                        w.text(line, x: margin, y: pdfY(y + 9), size: 9)
                        y += 12
                    }
                }
            case .keyValues(let items):
                for (k, v) in items {
                    let lines = wrap(v, width: usableWidth - 190, size: 9, bold: false, maxLines: 4)
                    ensureSpace(Double(lines.count) * 11 + 2)
                    w.text(k, x: margin + 4, y: pdfY(y + 9), size: 9, color: .gray)
                    for (i, line) in lines.enumerated() { w.text(line, x: margin + 190, y: pdfY(y + 9 + Double(i) * 11), size: 9, bold: true) }
                    y += Double(lines.count) * 11 + 2
                }
            case .table(let table):
                drawTable(table, w: w, y: &y, ensureSpace: ensureSpace)
            }
            y += 14
        }

        // Piè di pagina con numerazione
        let projectName = doc.meta.first { $0.0 == "Progetto" }?.1 ?? ""
        let scope = doc.meta.first { $0.0 == "Ambito" }?.1 ?? ""
        let date = ReportBuilder.dateTime(generatedAt)
        for (i, page) in w.pages.enumerated() {
            w.setCurrent(page)
            w.line(x1: margin, y1: 34, x2: PDFWriter.pageWidth - margin, y2: 34, color: .light)
            w.text("\(projectName) · \(scope)", x: margin, y: 22, size: 7.5, color: .gray)
            let right = "\(date) · Pagina \(i + 1) di \(w.pages.count)"
            w.text(right, x: PDFWriter.pageWidth - margin - PDFWriter.width(right, size: 7.5, bold: false), y: 22, size: 7.5, color: .gray)
        }
        return w.data(title: "\(doc.title) – \(projectName)", author: doc.meta.first { $0.0 == "Operatore" && $0.1 != ClipColumns.notAvailable }?.1)
    }

    // MARK: Tabelle

    private static func drawTable(_ table: ReportTable, w: PDFWriter, y: inout Double, ensureSpace: (Double) -> Void) {
        let fontSize = 7.5, lineHeight = 9.0, pad = 3.0, maxLines = 3
        let widths = columnWidths(table, fontSize: fontSize, pad: pad)
        func pdfY(_ fromTop: Double) -> Double { PDFWriter.pageHeight - fromTop }

        func drawRow(_ cells: [String], bold: Bool, fill: PDFWriter.Color?, textColors: [PDFWriter.Color?] = []) {
            let wrapped = cells.enumerated().map { (i, c) in wrap(c, width: widths[i] - 2 * pad, size: fontSize, bold: bold, maxLines: maxLines) }
            let lines = max(1, wrapped.map(\.count).max() ?? 1)
            let height = Double(lines) * lineHeight + 2 * pad
            if y + height > PDFWriter.pageHeight - bottom {
                w.newPage(); y = top
                drawHeader()
            }
            if let fill { w.fillRect(x: margin, y: pdfY(y + height), width: usableWidth, height: height, color: fill) }
            var x = margin
            for (i, lines) in wrapped.enumerated() {
                for (j, line) in lines.enumerated() {
                    let tx = table.columns[i].alignment == .right ? x + widths[i] - pad - PDFWriter.width(line, size: fontSize, bold: bold) : x + pad
                    let color = i < textColors.count ? (textColors[i] ?? .black) : .black
                    w.text(line, x: tx, y: pdfY(y + pad + lineHeight * Double(j) + lineHeight - 2), size: fontSize, bold: bold, color: color)
                }
                x += widths[i]
            }
            w.line(x1: margin, y1: pdfY(y + height), x2: margin + usableWidth, y2: pdfY(y + height), color: .light, width: 0.3)
            y += height
        }
        func drawHeader() {
            drawRow(table.columns.map(\.title), bold: true, fill: .light)
        }

        drawHeader()
        for (n, row) in table.rows.enumerated() {
            // lo stato problematico viene evidenziato in rosso, OK in verde
            let colors: [PDFWriter.Color?] = row.map { cell in
                switch cell.display {
                case "MISMATCH", "ERRORE": return .red
                case "OK": return .green
                default: return nil
                }
            }
            drawRow(row.map(\.display), bold: false, fill: n % 2 == 1 ? .zebra : nil, textColors: colors)
        }
        if let f = table.footer { drawRow(f.map(\.display), bold: true, fill: .light) }
    }

    /// Larghezze delle colonne: proporzionali ai pesi, ma mai più strette dell'intestazione e dei valori brevi (così non vanno a capo).
    static func columnWidths(_ table: ReportTable, fontSize: Double, pad: Double) -> [Double] {
        let count = table.columns.count
        guard count > 0 else { return [] }
        let totalWeight = max(0.001, table.columns.reduce(0) { $0 + $1.width })
        var widths = table.columns.map { usableWidth * $0.width / totalWeight }
        var minimum = [Double](repeating: 0, count: count)
        for (i, col) in table.columns.enumerated() {
            var longest = PDFWriter.width(col.title, size: fontSize, bold: true)
            for row in table.rows + (table.footer.map { [$0] } ?? []) where i < row.count {
                longest = max(longest, PDFWriter.width(row[i].display, size: fontSize, bold: false))
            }
            minimum[i] = min(longest, 95) + 2 * pad + 2          // le colonne con testo lungo (percorsi) possono andare a capo
        }
        for i in 0..<count { widths[i] = max(widths[i], minimum[i]) }
        let excess = widths.reduce(0, +) - usableWidth
        if excess > 0 {
            let reducible = (0..<count).reduce(0.0) { $0 + max(0, widths[$1] - minimum[$1]) }
            if reducible > 0 {
                let factor = min(1, excess / reducible)
                for i in 0..<count { widths[i] -= max(0, widths[i] - minimum[i]) * factor }
            }
            let total = widths.reduce(0, +)
            if total > usableWidth { widths = widths.map { $0 * usableWidth / total } }    // ultima risorsa: troppe colonne
        }
        return widths
    }

    // MARK: Testo

    /// Spezza il testo in righe che stanno nella larghezza data; le parole troppo lunghe (percorsi, hash) vengono spezzate a caratteri.
    static func wrap(_ text: String, width: Double, size: Double, bold: Bool, maxLines: Int) -> [String] {
        let width = max(width, 10)
        func w(_ s: String) -> Double { PDFWriter.width(s, size: size, bold: bold) }
        var lines: [String] = []
        var line = ""
        func push() { lines.append(line); line = "" }
        for word in text.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
            var rest = word
            while w(rest) > width {                       // parola più larga di una riga
                if !line.isEmpty { push() }
                var cut = rest.startIndex
                var acc = ""
                for ch in rest {
                    if w(acc + String(ch)) > width { break }
                    acc.append(ch)
                    cut = rest.index(after: cut)
                }
                if acc.isEmpty { acc = String(rest.first!); cut = rest.index(after: rest.startIndex) }
                lines.append(acc)
                rest = String(rest[cut...])
            }
            let candidate = line.isEmpty ? rest : line + " " + rest
            if w(candidate) <= width { line = candidate } else { push(); line = rest }
        }
        if !line.isEmpty || lines.isEmpty { push() }
        if lines.count > maxLines {
            var kept = Array(lines.prefix(maxLines))
            var last = kept[maxLines - 1]
            while !last.isEmpty && w(last + "…") > width { last.removeLast() }
            kept[maxLines - 1] = last + "…"
            return kept
        }
        return lines
    }
}

extension PDFWriter {
    func setCurrent(_ page: Page) { self.current = page }
}
