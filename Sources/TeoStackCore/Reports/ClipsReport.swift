import Foundation

/// «Clips Report»: riquadro Clips Overview e un'unica tabella larga con TUTTE le colonne e una riga per file, come nel formato di riferimento.
enum ClipsReport {
    private static let sidePadding = 5.0          // rientro del testo nella cella
    private static let lineHeight = 8.8
    private static let headerHeight = 12.8
    private static let boxInset = 5.6
    private static let clipRowHeight = 82.4       // riga con anteprima 102.4 × 70.4
    private static let otherRowHeight = 104.0     // riga con icona documento 92.8 × 92.8
    /// Proporzioni della pagina di riferimento (7987.17 / 11196.33); si allunga solo se le righe non ci stanno.
    private static let referenceRatio = 7987.17 / 11196.33
    private static let maxPageHeight = 14000.0

    static func render(_ ctx: ReportContext) -> Data {
        let columns = ReportFieldTable.selected(ctx.columnIDs)
        let tableWidth = max(columns.reduce(0) { $0 + $1.width }, 480)     // con poche colonne la pagina resta larga abbastanza per il riquadro riassuntivo
        let minHeight = (30.0 + 5.6 + tableWidth + 5.6 + 53.0) * referenceRatio

        // Misure con una pagina provvisoria: blocco titolo + riquadro riassuntivo, poi celle e altezze delle righe.
        let probe = ReportCanvas(ctx: ctx, setup: .clips(tableWidth: tableWidth, height: minHeight))
        let overviewTop = probe.drawTitleBlock() - 0.5
        let overviewBottom = probe.drawCompactOverview(top: overviewTop)
        let firstBoxTop = overviewBottom + 11.2

        let cells: [[FieldCell]] = ctx.items.map { item in columns.map { ReportFields.cell($0.title, item: item, ctx: ctx) } }
        let heights: [Double] = zip(ctx.items, cells).map { item, row in
            var h = item.isClip ? clipRowHeight : otherRowHeight
            for (i, cell) in row.enumerated() {
                if case .text(let t) = cell {
                    let lines = probe.wrap(t, width: columns[i].width - 2 * sidePadding, size: probe.setup.bodySize).count
                    h = max(h, Double(lines) * lineHeight + 20)
                }
            }
            return h
        }

        let needed = firstBoxTop + 11.2 + headerHeight + 0.8 + heights.reduce(0, +) + boxInset + 34.5 + 28.7
        let pageHeight = min(maxPageHeight, max(minHeight, needed))
        let canvas = ReportCanvas(ctx: ctx, setup: .clips(tableWidth: tableWidth, height: pageHeight))
        let setup = canvas.setup
        let pdf = canvas.pdf
        var images: [URL: Int] = [:]

        let titleBottom = canvas.drawTitleBlock()
        _ = canvas.drawCompactOverview(top: titleBottom - 0.5)

        let limit = setup.contentBottom - boxInset
        var row = 0
        var boxTop = firstBoxTop
        repeat {
            var y = boxTop + 11.2
            let left = setup.boxLeft + boxInset
            var xs: [Double] = []
            var x = left
            for c in columns { xs.append(x); x += c.width }

            for (i, c) in columns.enumerated() {
                pdf.fillRect(x: xs[i], y: y, width: c.width, height: headerHeight, color: .zebra)
                pdf.text(c.title, x: xs[i] + sidePadding - 0.2, top: y + 2.7, size: setup.bodySize, font: .monoBold)
            }
            y += headerHeight + 0.8

            var rowsOnPage = 0
            while row < ctx.items.count && (rowsOnPage == 0 || y + heights[row] <= limit) {
                draw(row: row, item: ctx.items[row], cells: cells[row], columns: columns, xs: xs, y: y, height: heights[row],
                     canvas: canvas, images: &images)
                y += heights[row]
                row += 1
                rowsOnPage += 1
            }
            canvas.drawBox(y: boxTop, height: y + boxInset - boxTop, title: nil)
            if row < ctx.items.count {
                canvas.newPage()
                boxTop = setup.contentTop
            }
        } while row < ctx.items.count
        canvas.decoratePages()
        return pdf.data(title: "\(ctx.kind.title) – \(ctx.title)", author: ctx.operatorName)
    }

    private static func draw(row: Int, item: ReportItem, cells: [FieldCell], columns: [(title: String, width: Double)], xs: [Double],
                             y: Double, height h: Double, canvas: ReportCanvas, images: inout [URL: Int]) {
        let pdf = canvas.pdf, size = canvas.setup.bodySize
        let center = y + h / 2
        let background: PDFWriter.Color = row % 2 == 0 ? .white : .zebra
        for (i, cell) in cells.enumerated() {
            let x0 = xs[i], w = columns[i].width
            pdf.fillRect(x: x0, y: y, width: w, height: h, color: background)
            if i > 0 { pdf.fillRect(x: x0, y: y, width: 0.8, height: h, color: PDFWriter.Color(hex: 0xF7F7F7)) }
            if i < cells.count - 1 { pdf.fillRect(x: x0 + w - 0.8, y: y, width: 0.8, height: h, color: PDFWriter.Color(hex: 0xF7F7F7)) }
            switch cell {
            case .empty: break
            case .text(let t):
                let lines = canvas.wrap(t, width: w - 2 * sidePadding, size: size)
                let top = center - Double(lines.count) * lineHeight / 2 + 0.2
                for (j, line) in lines.enumerated() {
                    pdf.text(line, x: x0 + sidePadding, top: top + Double(j) * lineHeight, size: size, font: .mono)
                }
            case .preview:
                canvas.drawThumbnail(item: item, imageIndexes: &images, x: x0 + w - 13.6 - 102.4, y: y + (item.isClip ? 2.4 : 1.6),
                                     maxWidth: 102.4, maxHeight: item.isClip ? 70.4 : 92.8, alignRight: true)
            case .flag:
                canvas.drawFlag(x: x0 + sidePadding + 1, y: center - 6.4, height: 12.8)
            case .rating:
                for k in 0..<5 { canvas.drawStar(cx: x0 + sidePadding + 6.1 + Double(k) * 12.2, cy: center, radius: 5.4, filled: false) }
            case .label(let t):
                pdf.circle(cx: x0 + sidePadding + 5.2, cy: center, radius: 4.8, strokeColor: PDFWriter.Color.line, lineWidth: 0.7)
                pdf.text(t, x: x0 + 15.5, top: center - lineHeight / 2 + 0.2, size: size, font: .mono)
            }
        }
    }
}
