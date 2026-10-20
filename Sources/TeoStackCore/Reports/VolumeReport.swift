import Foundation

/// «Volume Report»: un volume per pagina (la scheda e ogni disco di destinazione) con cartelle, file, XXH64 e dimensioni.
enum VolumeReport {
    private struct VolumeEntry {
        var name: String
        var usagePath: String?            // percorso per leggere lo spazio usato, se il volume è montato
        var files: [(folder: String, name: String, size: Int64, hash: String?)]
    }

    private static func volumeAndFolder(of path: String) -> (volume: String, folder: String) {
        let parts = path.split(separator: "/").map(String.init)
        if parts.count >= 2, parts[0] == "Volumes" { return (parts[1], parts.dropFirst(2).joined(separator: "/")) }
        return (ReportFormatting.volumeName(path), parts.joined(separator: "/"))
    }

    private static func collect(_ ctx: ReportContext) -> [VolumeEntry] {
        var order: [String] = []
        var entries: [String: VolumeEntry] = [:]
        func add(path: String, item: ReportItem) {
            let (volume, rootFolder) = volumeAndFolder(of: (path as NSString).deletingLastPathComponent)
            if entries[volume] == nil {
                order.append(volume)
                let usage = path.hasPrefix("/Volumes/") ? "/Volumes/" + volume : nil
                entries[volume] = VolumeEntry(name: volume, usagePath: usage, files: [])
            }
            entries[volume]!.files.append((rootFolder, item.fileName, item.clip.size, item.clip.sourceHash))
        }
        for item in ctx.items {
            if let source = item.sourcePath { add(path: source, item: item) }
            for (d, path) in item.destinationPaths.enumerated() where d < item.clip.destinationStatuses.count && item.clip.destinationStatuses[d] == "ok" {
                add(path: path, item: item)
            }
        }
        return order.compactMap { entries[$0] }
    }

    /// «1.20 TB of 8.00 TB used» e quota usata, o nil se il volume non è raggiungibile.
    private static func usage(_ entry: VolumeEntry) -> (text: String, share: Double)? {
        guard let path = entry.usagePath, let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let total = (attrs[.systemSize] as? NSNumber)?.int64Value, let free = (attrs[.systemFreeSize] as? NSNumber)?.int64Value, total > 0
        else { return nil }
        let used = total - free
        return ("\(ReportFormatting.size(used)) of \(ReportFormatting.size(total)) used", Double(used) / Double(total))
    }

    static func render(_ ctx: ReportContext) -> Data {
        let canvas = ReportCanvas(ctx: ctx, setup: .volume())
        let pdf = canvas.pdf
        let setup = canvas.setup
        let volumes = collect(ctx)
        let rowHeight = 73.6, folderHeight = 23.2
        let left = 35.6, right = setup.width - 35.6 - 0.0     // 559.7
        let sizeRight = right - 3.5                           // bordo destro del testo della dimensione

        if volumes.isEmpty {
            canvas.drawBox(y: 137.0, height: 40, title: nil)
            pdf.text("No files", x: 40, top: 150, size: 9.6, font: .mono, color: .gray)
        }

        for (index, volume) in volumes.enumerated() {
            if index > 0 { canvas.newPage() }
            // intestazione del volume
            drawDriveIcon(pdf, x: 40.4, y: 73.0, size: 53.6)
            pdf.text(volume.name, x: 104.4, top: 75.9, size: 14.94, font: .mono)
            if ctx.projectName != volume.name {
                pdf.text(ctx.projectName, x: 104.4, top: 97.7, size: 9.6, font: .mono)
            }
            let u = usage(volume)
            pdf.text(u?.text ?? "N/A of N/A used", x: 276.2, top: 78.3, size: 10.67, font: .mono)
            let barX = 276.2 + PDFWriter.width(u?.text ?? "N/A of N/A used", size: 10.67, font: .mono) + 7.0
            pdf.strokeRoundedRect(x: barX + 0.4, y: 76.6, width: 108.1, height: 13.6, radius: 1.8, lineWidth: 0.8, color: .line)
            if let share = u?.share, share > 0 {
                pdf.fillRoundedRect(x: barX + 0.9, y: 77.1, width: 107.1 * share, height: 12.6, radius: 1.4, color: .line)
            }

            // cartelle e file
            let folders = Dictionary(grouping: volume.files, by: { $0.folder }).sorted { $0.key < $1.key }
            var boxTop = 137.0
            var y = boxTop + 11.2
            var open = true
            func closeBox() {
                canvas.drawBox(y: boxTop, height: y - boxTop + 6.4, title: nil)
            }
            for (folder, files) in folders {
                let sorted = files.sorted { $0.name < $1.name }          // ordine per byte, come nel riferimento
                func folderRow() {
                    pdf.fillRect(x: left, y: y, width: right - left, height: folderHeight, color: .zebra)
                    pdf.polygon([(37.2 + 0.5, 157.0 - 148.2 + y + 0.8), (37.2 + 7.5, 157.0 - 148.2 + y + 0.8), (37.2 + 4.0, 157.0 - 148.2 + y + 6.8)],
                                fillColor: PDFWriter.Color(hex: 0x8E8E8E))
                    pdf.text(folder.isEmpty ? volume.name : folder, x: 48.7, top: y + 5.3, size: 10.67, font: .monoBold)
                    pdf.text(ReportFormatting.size(sorted.reduce(0) { $0 + $1.size }), x: sizeRight - 100, top: y + 5.5, size: 9.6, font: .mono,
                             align: .right, width: 100)
                    y += folderHeight
                }
                if y + folderHeight + rowHeight > setup.contentBottom { closeBox(); canvas.newPage(); boxTop = setup.contentTop; y = boxTop + 11.2 }
                folderRow()
                for (n, f) in sorted.enumerated() {
                    if y + rowHeight > setup.contentBottom {
                        closeBox(); canvas.newPage(); boxTop = setup.contentTop; y = boxTop + 11.2; folderRow()
                    }
                    pdf.fillRect(x: left, y: y, width: right - left, height: rowHeight, color: n % 2 == 1 ? .zebra : .white)
                    pdf.text(f.name, x: 57.2, top: y + 4.5, size: 10.67, font: .monoBold)
                    if let h = f.hash {
                        pdf.text("xxHash64:\(ReportFormatting.littleEndian(hex: h))", x: 57.2, top: y + 26.3, size: 9.6, font: .mono)
                        pdf.text("xxHash64BE:\(h)", x: 57.2, top: y + 47.1, size: 9.6, font: .mono)
                    } else {
                        pdf.text("xxHash64: N/D", x: 57.2, top: y + 26.3, size: 9.6, font: .mono)
                    }
                    pdf.text(ReportFormatting.size(f.size), x: sizeRight - 100, top: y + 31.1, size: 9.6, font: .mono, align: .right, width: 100)
                    y += rowHeight
                }
            }
            if open { closeBox(); open = false }
        }
        canvas.decoratePages()
        return pdf.data(title: "\(ctx.kind.title) – \(ctx.title)", author: ctx.operatorName)
    }

    /// Icona «disco esterno» (vettoriale).
    static func drawDriveIcon(_ pdf: PDFWriter, x: Double, y: Double, size: Double) {
        let s = size / 53.6
        func X(_ v: Double) -> Double { x + v * s }
        func Y(_ v: Double) -> Double { y + v * s }
        pdf.fillRoundedRect(x: X(7), y: Y(1), width: 40 * s, height: 44 * s, radius: 5 * s, color: PDFWriter.Color(hex: 0xD98A00))
        pdf.fillRoundedRect(x: X(9), y: Y(3), width: 36 * s, height: 20 * s, radius: 4 * s, color: PDFWriter.Color(hex: 0xF5B52E))
        pdf.fillRoundedRect(x: X(9), y: Y(23), width: 36 * s, height: 20 * s, radius: 4 * s, color: PDFWriter.Color(hex: 0xFFC83D))
        pdf.fillRoundedRect(x: X(3), y: Y(41), width: 48 * s, height: 11 * s, radius: 5 * s, color: PDFWriter.Color(hex: 0x6C6C6C))
        pdf.circle(cx: X(44), cy: Y(47), radius: 1.5 * s, fillColor: PDFWriter.Color(hex: 0x7ED321))
    }
}
