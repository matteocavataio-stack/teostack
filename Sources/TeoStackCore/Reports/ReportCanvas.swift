import Foundation

/// Impostazioni di pagina di un report (misure del formato di riferimento).
struct PageSetup {
    var width: Double
    var height: Double
    var headerTop: Double          // bordo alto del testo dell'intestazione
    var contentTop: Double         // inizio dell'area di contenuto
    var bodySize: Double           // corpo del testo (Menlo)
    var titleToProject: Double = 31.0
    var projectToOffload: Double = 16.8
    var boxRightMargin: Double = 30.0
    var textRightMargin: Double = 18.2         // margine destro di data e numero di pagina

    var footerTop: Double { height - 28.7 }
    var contentBottom: Double { height - 34.5 }
    var boxLeft: Double { 30.0 }
    var boxRight: Double { width - boxRightMargin }
    var boxWidth: Double { boxRight - boxLeft }

    /// Misure per scala del corpo: le pagine del riferimento hanno corpi 9.6 (Shooting Day, Volume) o 7.4 (gli altri).
    static func shootingDay() -> PageSetup { PageSetup(width: 632.667, height: 894.76, headerTop: 41.3, contentTop: 57.0, bodySize: 9.61) }
    static func volume() -> PageSetup { PageSetup(width: 595.276, height: 841.89, headerTop: 41.3, contentTop: 57.0, bodySize: 9.6) }
    static func thumbnail() -> PageSetup {
        PageSetup(width: 595.276, height: 841.89, headerTop: 41.3, contentTop: 57.0, bodySize: 7.47, titleToProject: 31.3, projectToOffload: 14.4)
    }
    /// «Clips Report»: una sola pagina larga quanto la somma delle colonne (il riferimento è 11196 × 7987 pt).
    static func clips(tableWidth: Double, height: Double) -> PageSetup {
        PageSetup(width: 30.0 + 5.6 + tableWidth + 5.6 + 53.0, height: height, headerTop: 18.3, contentTop: 34.0, bodySize: 7.47,
                  titleToProject: 31.3, projectToOffload: 14.4, boxRightMargin: 53.0, textRightMargin: 41.1)
    }
    static func contactPrint() -> PageSetup {
        PageSetup(width: 841.89, height: 595.276, headerTop: 18.3, contentTop: 34.0, bodySize: 7.43, titleToProject: 31.1,
                  projectToOffload: 14.4, boxRightMargin: 53.0)
    }
}

enum CellContent {
    case text(String)
    case bar(Double)                 // quota 0...1 («Share in Clips»)
    case stars(Int)                  // stelle piene su 5
    case label(String)               // cerchio + testo
    case flag(String)                // bandierina + testo
    case blank
}

struct TableColumn {
    var title: String
    var alignment: PDFWriter.Align = .left
    var isBar = false
    /// Larghezza fissa (punti alla scala 9.61) quando il riferimento non la ricava dal contenuto (colonna «Size»).
    var fixedWidth: Double? = nil
}

/// Disegno condiviso dei report: intestazione/piè di pagina, blocco titolo, riquadri e tabelle.
final class ReportCanvas {
    let pdf: PDFWriter
    let ctx: ReportContext
    let setup: PageSetup
    var y: Double

    init(ctx: ReportContext, setup: PageSetup) {
        self.ctx = ctx
        self.setup = setup
        pdf = PDFWriter(width: setup.width, height: setup.height)
        y = setup.contentTop
    }

    // MARK: Pagine

    func newPage() {
        pdf.newPage()
        y = setup.contentTop
    }

    func ensureSpace(_ height: Double) {
        if y + height > setup.contentBottom && y > setup.contentTop + 1 { newPage() }
    }

    /// Testo in alto a sinistra e data a destra; piè di pagina con nome dell'app e «pagina/totale».
    func decoratePages() {
        let total = pdf.pages.count
        let date = ReportFormatting.dateTime(ctx.generatedAt)
        for (i, page) in pdf.pages.enumerated() {
            pdf.select(page: i)
            let right = page.width - setup.textRightMargin
            let headerTop = setup.headerTop + 1.1
            pdf.text(ctx.kind.title, x: 18.0, top: headerTop, size: 9, font: .sans)
            pdf.text(date, x: right - 200, top: headerTop, size: 9, font: .sans, align: .right, width: 200)
            let footerTop = page.height - 28.7 + 1.1
            pdf.text("TeoStackXt", x: 18.0, top: footerTop, size: 9, font: .sans)
            pdf.text("\(i + 1)/\(total)", x: right - 100, top: footerTop, size: 9, font: .sans, align: .right, width: 100)
        }
    }

    // MARK: Blocco titolo

    /// Titolo grande (bin/giorno/progetto), progetto in grigio e «Offload started at …». Restituisce il bordo basso del blocco.
    @discardableResult
    func drawTitleBlock() -> Double {
        let top = setup.contentTop + 21.8
        pdf.text(ctx.title, x: 40.4, top: top, size: 21.34, font: .mono)
        var next = top + setup.titleToProject
        if ctx.projectName != ctx.title {
            pdf.text(ctx.projectName, x: 40.4, top: next, size: setup.bodySize, font: .mono, color: .gray)
        }
        next += setup.projectToOffload
        if let d = ctx.offloadStarted {
            pdf.text("Offload started at \(ReportFormatting.dateTime(d))", x: 40.4, top: next, size: setup.bodySize, font: .mono, color: .gray)
        }
        return next + 45.0                                   // bordo alto del primo riquadro
    }

    // MARK: Riquadri

    func drawBox(x: Double? = nil, y top: Double, width: Double? = nil, height: Double, title: String?) {
        let bx = x ?? setup.boxLeft, bw = width ?? setup.boxWidth
        pdf.strokeRoundedRect(x: bx + 0.4, y: top + 0.4, width: bw - 0.8, height: height - 0.8, radius: 1.8, lineWidth: 0.8, color: .line)
        if let title {
            pdf.text(title, x: bx + 5.9, top: top + (setup.bodySize > 8.5 ? setup.bodySize * 0.572 : 5.9 * setup.bodySize / 7.47), size: setup.bodySize, font: .monoItalic)
        }
    }

    // MARK: Tabelle

    struct TableStyle {
        var bodySize: Double
        var headerSize: Double
        var headerHeight: Double
        var rowHeight: Double
        var rowPitchExtra: Double = 0          // spazio tra righe (tabelle «compatte»)
        var padding: Double
        var cellGap: Double = 0                // spazio tra celle (tabelle «compatte»)
        var compact = false                    // larghezza = contenuto (altrimenti riempie il riquadro)
        var firstRowShaded = false
        var edgeRowExtra = 0.9                 // prima e ultima riga leggermente più alte
        var barWidth = 108.1
        var barPaddingLeft = 7.2
        var barPaddingRight = 8.0
    }

    func fillStyle() -> TableStyle {
        let s = setup.bodySize / 9.61
        return TableStyle(bodySize: setup.bodySize, headerSize: setup.bodySize, headerHeight: 21.6 * s, rowHeight: 24.8 * s,
                          padding: 7.7 * s, barWidth: 108.1 * s, barPaddingLeft: 7.2 * s, barPaddingRight: 8.0 * s)
    }

    func compactStyle() -> TableStyle {
        let s = setup.bodySize / 7.43
        return TableStyle(bodySize: setup.bodySize, headerSize: 11.15 * s, headerHeight: 19.1 * s, rowHeight: 15.1 * s,
                          rowPitchExtra: 1.6 * s, padding: 7.2 * s, cellGap: 1.6 * s, compact: true, firstRowShaded: true, edgeRowExtra: 0)
    }

    private func chars(_ s: String) -> Int { s.count }

    private func width(_ s: String, _ size: Double, bold: Bool = false) -> Double {
        PDFWriter.width(s, size: size, font: bold ? .monoBold : .mono)
    }

    /// Spezza il testo (parole, poi caratteri) in righe che stanno nella larghezza.
    func wrap(_ text: String, width maxWidth: Double, size: Double) -> [String] {
        let maxChars = max(1, Int((maxWidth / (PDFWriter.monoAdvance * size) + 0.01).rounded(.down)))
        var lines: [String] = []
        for paragraph in text.components(separatedBy: "\n") {
            var line = ""
            for word in paragraph.split(separator: " ", omittingEmptySubsequences: false).map(String.init) {
                var rest = word
                while rest.count > maxChars {
                    if !line.isEmpty { lines.append(line); line = "" }
                    lines.append(String(rest.prefix(maxChars)))
                    rest = String(rest.dropFirst(maxChars))
                }
                let candidate = line.isEmpty ? rest : line + " " + rest
                if candidate.count <= maxChars { line = candidate } else { lines.append(line); line = rest }
            }
            lines.append(line)
        }
        return lines
    }

    /// Larghezze delle colonne (come una tabella HTML con layout automatico).
    func columnWidths(columns: [TableColumn], rows: [[CellContent]], style st: TableStyle, available: Double) -> [Double] {
        let n = columns.count
        var maxW = [Double](repeating: 0, count: n), minW = [Double](repeating: 0, count: n)
        let barOuter = st.barPaddingLeft + st.barWidth + st.barPaddingRight
        for i in 0..<n {
            if columns[i].isBar { maxW[i] = barOuter; minW[i] = barOuter; continue }
            if let fixed = columns[i].fixedWidth { maxW[i] = fixed * st.bodySize / 9.61; minW[i] = maxW[i]; continue }
            var longest = width(columns[i].title, st.headerSize, bold: true) + 2 * st.padding
            var longestWord = columns[i].title.split(separator: " ").map { width(String($0), st.headerSize, bold: true) }.max() ?? 0
            longestWord += 2 * st.padding
            for r in rows where i < r.count {
                let t = displayText(r[i])
                longest = max(longest, width(t.replacingOccurrences(of: "\n", with: " "), st.bodySize) + 2 * st.padding + iconIndent(r[i], st))
                for w in t.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
                    longestWord = max(longestWord, width(String(w), st.bodySize) + 2 * st.padding + iconIndent(r[i], st))
                }
            }
            maxW[i] = longest; minW[i] = min(longestWord, longest)
        }
        if st.compact {
            // il riferimento calcola le colonne con corpo 7.43/11.15 (multipli di 0.8) anche quando il testo è 7.47
            let k = 7.43 / st.bodySize
            return maxW.map { ((($0 - 2 * st.padding) * k + 2 * st.padding) / 0.8 - 1e-9).rounded(.up) * 0.8 }
        }
        let totalMax = maxW.reduce(0, +), totalMin = minW.reduce(0, +)
        if totalMax <= available {                         // spazio in più: proporzionale al contenuto (colonna barra fissa)
            let flexMax = zip(maxW, columns).filter { !$0.1.isBar && $0.1.fixedWidth == nil }.reduce(0) { $0 + $1.0 }
            let extra = available - totalMax
            return zip(maxW, columns).map { ($0.1.isBar || $0.1.fixedWidth != nil) ? $0.0 : $0.0 + extra * ($0.0 / max(flexMax, 1)) }
        }
        let t = totalMax - totalMin > 0 ? max(0, (available - totalMin) / (totalMax - totalMin)) : 0
        return (0..<n).map { minW[$0] + (maxW[$0] - minW[$0]) * t }
    }

    /// Righe di una cella; le tabelle compatte hanno la larghezza del contenuto e non vanno mai a capo.
    private func cellLines(_ text: String, width w: Double, style st: TableStyle) -> [String] {
        st.compact ? text.components(separatedBy: "\n") : wrap(text, width: w - 2 * st.padding, size: st.bodySize)
    }

    private func displayText(_ c: CellContent) -> String {
        switch c {
        case .text(let s), .label(let s), .flag(let s): return s
        case .stars: return String(repeating: "x", count: 5)
        default: return ""
        }
    }

    private func iconIndent(_ c: CellContent, _ st: TableStyle) -> Double {
        switch c {
        case .label, .flag: return 15.7 * st.bodySize / 9.61
        case .stars: return 0
        default: return 0
        }
    }

    struct TableLayout {
        var widths: [Double]
        var rowHeights: [Double]
        var totalHeight: Double
    }

    func layoutTable(columns: [TableColumn], rows: [[CellContent]], style st: TableStyle, width available: Double) -> TableLayout {
        let widths = columnWidths(columns: columns, rows: rows, style: st, available: available)
        var heights: [Double] = []
        for (r, row) in rows.enumerated() {
            var lines = 1
            for (i, cell) in row.enumerated() where i < columns.count {
                if case .text(let t) = cell { lines = max(lines, cellLines(t, width: widths[i], style: st).count) }
            }
            let edge = (r == 0 || r == rows.count - 1) ? st.edgeRowExtra : 0
            var h = st.rowHeight + edge
            if lines > 1 { h = max(h, Double(lines) * st.bodySize * 1.1655 + (st.rowHeight - st.bodySize * 1.1655)) }
            heights.append(h)
        }
        let total = st.headerHeight + st.rowPitchExtra + heights.reduce(0) { $0 + $1 + st.rowPitchExtra } - (rows.isEmpty ? st.rowPitchExtra : st.rowPitchExtra)
        return TableLayout(widths: widths, rowHeights: heights, totalHeight: total)
    }

    func tableHeight(columns: [TableColumn], rows: [[CellContent]], style st: TableStyle, width: Double) -> Double {
        layoutTable(columns: columns, rows: rows, style: st, width: width).totalHeight
    }

    /// Disegna una tabella in (x, y) con la larghezza data. Restituisce l'altezza usata.
    @discardableResult
    func drawTable(columns: [TableColumn], rows: [[CellContent]], style st: TableStyle, x: Double, y top: Double, width available: Double) -> Double {
        let layout = layoutTable(columns: columns, rows: rows, style: st, width: available)
        let widths = layout.widths
        let xs = widths.indices.map { i in x + widths[..<i].reduce(0, +) + Double(i) * st.cellGap }
        var cursor = top

        for (i, c) in columns.enumerated() {
            pdf.fillRect(x: xs[i], y: cursor, width: widths[i], height: st.headerHeight, color: .zebra)
            let textTop = cursor + (st.headerHeight - st.headerSize * 1.1655) / 2 + 0.2
            pdf.text(c.title, x: xs[i] + st.padding, top: textTop, size: st.headerSize, font: .monoBold,
                     align: c.alignment, width: widths[i] - 2 * st.padding)
        }
        cursor += st.headerHeight + st.rowPitchExtra

        for (r, row) in rows.enumerated() {
            let shaded = st.firstRowShaded ? r % 2 == 0 : r % 2 == 1
            let h = layout.rowHeights[r]
            for (i, cell) in row.enumerated() where i < columns.count {
                pdf.fillRect(x: xs[i], y: cursor, width: widths[i], height: h, color: shaded ? .zebra : .white)
                drawCell(cell, column: columns[i], x: xs[i], y: cursor, width: widths[i], height: h, style: st)
            }
            cursor += h + st.rowPitchExtra
        }
        return layout.totalHeight
    }

    private func drawCell(_ cell: CellContent, column: TableColumn, x: Double, y: Double, width w: Double, height h: Double, style st: TableStyle) {
        let textHeight = st.bodySize * 1.1655
        switch cell {
        case .blank: break
        case .text(let t):
            let lines = cellLines(t, width: w, style: st)
            let total = Double(lines.count) * textHeight
            let top = y + (h - total) / 2
            for (j, line) in lines.enumerated() {
                pdf.text(line, x: x + st.padding, top: top + Double(j) * textHeight, size: st.bodySize, font: .mono,
                         align: column.alignment, width: w - 2 * st.padding)
            }
        case .bar(let share):
            let bx = x + st.barPaddingLeft, by = y + (h - 11.2 * st.bodySize / 9.61) / 2 + 1.4 * st.bodySize / 9.61
            let bh = 11.2 * st.bodySize / 9.61
            pdf.strokeRoundedRect(x: bx + 0.4, y: by + 0.4, width: st.barWidth - 0.8, height: bh - 0.8, radius: 1.8, lineWidth: 0.8, color: .line)
            let inner = (st.barWidth - 1.6) * max(0, min(1, share))
            if inner > 0.5 {
                pdf.fillRoundedRect(x: bx + 0.8, y: by + 0.8, width: inner, height: bh - 1.6, radius: 1.4, color: .line)
            }
        case .stars(let filled):
            let size = 5.9 * st.bodySize / 9.61
            let cy = y + h / 2
            for k in 0..<5 {
                drawStar(cx: x + st.padding + size / 2 + Double(k) * size * 1.02, cy: cy, radius: size / 2, filled: k < filled)
            }
        case .label(let t):
            let r = 5.2 * st.bodySize / 9.61
            pdf.circle(cx: x + st.padding + r, cy: y + h / 2 - 0.5, radius: r - 0.4, strokeColor: Color.line, lineWidth: 0.8)
            pdf.text(t, x: x + st.padding + 2 * r + 0.3, top: y + (h - textHeight) / 2, size: st.bodySize, font: .mono)
        case .flag(let t):
            drawFlag(x: x + st.padding + 1, y: y + h / 2 - 5, height: 10 * st.bodySize / 9.61)
            pdf.text(t, x: x + st.padding + 2 * 5.2 + 0.3, top: y + (h - textHeight) / 2, size: st.bodySize, font: .mono)
        }
    }

    typealias Color = PDFWriter.Color

    // MARK: Icone vettoriali

    func drawStar(cx: Double, cy: Double, radius: Double, filled: Bool) {
        var pts: [(Double, Double)] = []
        for i in 0..<10 {
            let a = -Double.pi / 2 + Double(i) * Double.pi / 5
            let r = i % 2 == 0 ? radius : radius * 0.42
            pts.append((cx + r * cos(a), cy + r * sin(a)))
        }
        if filled { pdf.polygon(pts, fillColor: Color.black) } else { pdf.polygon(pts, strokeColor: Color.gray, lineWidth: 0.5) }
    }

    /// Bandierina «contorno» (segnalibro dei clip).
    func drawFlag(x: Double, y: Double, height: Double) {
        let w = height * 0.85
        pdf.line(x1: x, y1: y, x2: x, y2: y + height, color: Color(hex: 0xA0A0A0), width: 0.7)
        pdf.polygon([(x, y), (x + w, y + height * 0.2), (x, y + height * 0.55)], strokeColor: Color(hex: 0xA0A0A0), lineWidth: 0.7)
    }
}
