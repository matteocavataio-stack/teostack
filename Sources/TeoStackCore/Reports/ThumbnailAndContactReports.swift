import Foundation

extension ReportCanvas {
    /// Riquadro «Clips Overview» in stile compatto (Thumbnail e Contact Print Report). Restituisce il bordo basso del riquadro.
    @discardableResult
    func drawCompactOverview(top: Double) -> Double {
        let st = compactStyle()
        let s = setup.bodySize / 7.43
        func stats(_ items: [ReportItem]) -> [CellContent] {
            let clips = items.filter { $0.isClip }
            let known = clips.compactMap(\.durationSeconds)
            var duration = clips.isEmpty ? "0 sec" : (known.isEmpty ? ClipColumns.reportNotAvailable : ReportFormatting.duration(known.reduce(0, +)))
            if !known.isEmpty && known.count < clips.count { duration = "≥ " + duration }
            return [.text(String(clips.count)), .text(duration), .text(String(items.count)),
                    .text(ReportFormatting.size(items.reduce(Int64(0)) { $0 + $1.clip.size }))]
        }
        let columns = [TableColumn(title: ""), TableColumn(title: "Clips", alignment: .right), TableColumn(title: "Duration", alignment: .right),
                       TableColumn(title: "Files", alignment: .right), TableColumn(title: "Size", alignment: .right)]
        let rows: [[CellContent]] = [
            [.text("Source Video Clips")] + stats(ctx.videoClips),
            [.text("Audio Clips")] + stats(ctx.audioClips),
            [.text("Other Files")] + stats(ctx.otherFiles),
            [.text("Transcoded Clips")] + stats([]),
            [.text("Total")] + stats(ctx.items),
        ]
        let tableTop = top + 21.6 * s
        let tableX = setup.boxLeft + 15.2 * s
        let h = tableHeight(columns: columns, rows: rows, style: st, width: 0)
        let boxHeight = 21.6 * s + h + 12.8 * s
        drawBox(y: top, height: boxHeight, title: "Clips Overview")
        drawTable(columns: columns, rows: rows, style: st, x: tableX, y: tableTop, width: 0)
        return top + boxHeight
    }

    /// Immagine del clip dentro il riquadro (max w×h), allineata a destra/in alto o centrata; segnaposto se manca.
    func drawThumbnail(item: ReportItem, imageIndexes: inout [URL: Int], x: Double, y: Double, maxWidth: Double, maxHeight: Double,
                       alignRight: Bool) {
        if let url = item.thumbnail {
            let index: Int?
            if let known = imageIndexes[url] { index = known }
            else if let data = try? Data(contentsOf: url), let added = pdf.addJPEG(data) { imageIndexes[url] = added; index = added }
            else { index = nil }
            if let index {
                let size = pdf.imageSize(index)
                let scale = min(maxWidth / Double(size.width), maxHeight / Double(size.height))
                let w = Double(size.width) * scale, h = Double(size.height) * scale
                pdf.image(index, x: alignRight ? x + maxWidth - w : x + (maxWidth - w) / 2, y: y, width: w, height: h)
                return
            }
        }
        if item.isClip {
            // clip senza anteprima: riquadro grigio con la scritta
            let w = min(maxWidth, maxHeight * 1.46), h = w / 1.46
            let bx = alignRight ? x + maxWidth - w : x + (maxWidth - w) / 2
            pdf.fillRect(x: bx, y: y, width: w, height: h, color: PDFWriter.Color(hex: 0xE6E6E6))
            pdf.text("No preview", x: bx, top: y + h / 2 - 4, size: 7.0, font: .mono, color: .gray, align: .center, width: w)
        } else {
            drawDocumentIcon(x: x + maxWidth - 92.8 * min(1, maxHeight / 92.8), y: y, size: min(maxHeight, 92.8))
        }
    }

    /// Icona «documento» per i file che non sono clip (ALE, BIN, XML…).
    func drawDocumentIcon(x: Double, y: Double, size: Double) {
        let s = size / 92.8
        let w = 62.0 * s, h = 80.0 * s, left = x + (size - w) / 2, top = y + 6 * s, fold = 18 * s
        let shadow = PDFWriter.Color(hex: 0xD8D8D8), edge = PDFWriter.Color(hex: 0xBEBEBE)
        pdf.fillRoundedRect(x: left + 1.5 * s, y: top + 2.0 * s, width: w, height: h, radius: 2.5 * s, color: shadow)
        pdf.polygon([(left, top), (left + w - fold, top), (left + w, top + fold), (left + w, top + h), (left, top + h)],
                    fillColor: PDFWriter.Color(hex: 0xFBFBFB), strokeColor: edge, lineWidth: 0.6)
        pdf.polygon([(left + w - fold, top), (left + w - fold, top + fold), (left + w, top + fold)], fillColor: PDFWriter.Color(hex: 0xE4E4E4), strokeColor: edge, lineWidth: 0.6)
    }
}

/// «Thumbnail Report»: una scheda per ogni file con anteprima (o icona) e TUTTI i campi, come nel formato di riferimento.
enum ThumbnailReport {
    static func render(_ ctx: ReportContext) -> Data {
        let canvas = ReportCanvas(ctx: ctx, setup: .thumbnail())
        let pdf = canvas.pdf
        let setup = canvas.setup
        let size = setup.bodySize
        var images: [URL: Int] = [:]

        let boxTop = canvas.drawTitleBlock()
        var y = canvas.drawCompactOverview(top: boxTop - 0.5) + 13.6
        let labelRight = 419.1, valueLeft = 427.6, valueWidth = setup.width - 18.2 - valueLeft - 6
        let titles = ReportFieldTable.selected(ctx.columnIDs).map(\.title).filter { $0 != "Preview" }
        let pitch = 13.0667, lineHeight = 8.8

        for item in ctx.items {
            // la scheda inizia con l'immagine: serve spazio per almeno immagine e qualche campo
            if y + 100 > setup.contentBottom { canvas.newPage(); y = setup.contentTop }
            canvas.drawThumbnail(item: item, imageIndexes: &images, x: 69.2, y: y - 1.9, maxWidth: 135.2, maxHeight: 92.8, alignRight: true)
            var rowTop = y
            for title in titles {
                let cell = ReportFields.cell(title, item: item, ctx: ctx)
                var height = pitch
                var lines: [String] = []
                switch cell {
                case .text(let t):
                    lines = canvas.wrap(t, width: valueWidth, size: size)
                    if lines.count > 1 { height = max(pitch, Double(lines.count) * lineHeight + 4.3) }
                case .flag: height = 17.6
                case .rating: height = 28.0
                case .label: height = 15.2
                default: break
                }
                if rowTop + height > setup.contentBottom {
                    canvas.newPage()
                    rowTop = setup.contentTop
                }
                pdf.text(title, x: labelRight - 250, top: rowTop, size: size, font: .mono, color: .gray, align: .right, width: 250)
                switch cell {
                case .text:
                    for (j, line) in lines.enumerated() {
                        pdf.text(line, x: valueLeft, top: rowTop + Double(j) * lineHeight, size: size, font: .mono)
                    }
                case .flag: canvas.drawFlag(x: valueLeft + 2, y: rowTop - 0.2, height: 12.0)
                case .rating:
                    for k in 0..<5 { canvas.drawStar(cx: valueLeft + 6 + Double(k) * 12.2, cy: rowTop + 12.0, radius: 5.4, filled: false) }
                case .label(let t):
                    pdf.circle(cx: valueLeft + 5.0, cy: rowTop + 5.6, radius: 4.8, strokeColor: PDFWriter.Color.line, lineWidth: 0.7)
                    pdf.text(t, x: 438.3, top: rowTop, size: size, font: .mono)
                default: break
                }
                rowTop += height
            }
            y = rowTop + 33.6 - 13.0667 + 0.2
        }
        canvas.decoratePages()
        return pdf.data(title: "\(ctx.kind.title) – \(ctx.title)", author: ctx.operatorName)
    }
}

/// «Contact Print Report»: riquadro Clips Overview e griglia di anteprime dei clip video con il nome sotto ognuna.
enum ContactPrintReport {
    static func render(_ ctx: ReportContext) -> Data {
        let canvas = ReportCanvas(ctx: ctx, setup: .contactPrint())
        let pdf = canvas.pdf
        let setup = canvas.setup
        var images: [URL: Int] = [:]

        let boxTop = canvas.drawTitleBlock()
        var y = canvas.drawCompactOverview(top: boxTop - 0.7) + 15.1
        let cellWidth = 184.0, imageWidth = 124.3, imageHeight = 85.2, rowPitch = 112.0
        let columns = max(1, Int((setup.boxWidth - 1) / cellWidth))
        var column = 0
        for item in ctx.videoClips {
            if column == 0 && y + rowPitch - 13 > setup.contentBottom { canvas.newPage(); y = setup.contentTop + 4 }
            let cellLeft = 27.15 + Double(column) * cellWidth
            canvas.drawThumbnail(item: item, imageIndexes: &images, x: cellLeft + (cellWidth - imageWidth) / 2, y: y, maxWidth: imageWidth,
                                 maxHeight: imageHeight, alignRight: false)
            pdf.text(item.name, x: cellLeft, top: y + imageHeight + 5.1, size: setup.bodySize, font: .mono, align: .center, width: cellWidth)
            column += 1
            if column == columns { column = 0; y += rowPitch }
        }
        canvas.decoratePages()
        return pdf.data(title: "\(ctx.kind.title) – \(ctx.title)", author: ctx.operatorName)
    }
}
