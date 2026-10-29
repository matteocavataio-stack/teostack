import Foundation

/// «Shooting Day Report»: riquadri con le tabelle di riepilogo (Clips Overview, Workflow, Labels & Flags, Ratings, Backups, Bins,
/// Video Reels, Camera Sums, Video Formats, Audio Tapes), come nel formato di riferimento.
enum ShootingDayReport {
    private struct Stats {
        var clips = 0, files = 0
        var duration = 0.0
        var durationKnown = 0, durationExpected = 0
        var size: Int64 = 0

        init(_ items: [ReportItem], clipsOnly: Bool = false) {
            for i in items {
                files += 1
                size += i.clip.size
                if i.isClip {
                    clips += 1
                    durationExpected += 1
                    if let d = i.durationSeconds { duration += d; durationKnown += 1 }
                }
            }
        }

        var durationText: String {
            if clips == 0 { return "0 sec" }
            if durationKnown == 0 { return ClipColumns.reportNotAvailable }
            let t = ReportFormatting.duration(duration)
            return durationKnown < durationExpected ? "≥ \(t)" : t
        }
    }

    static func render(_ ctx: ReportContext) -> Data {
        let canvas = ReportCanvas(ctx: ctx, setup: .shootingDay())
        let st = canvas.fillStyle()
        let scale = canvas.setup.bodySize / 9.61
        let totalClips = max(1, ctx.allClips.count)
        var boxY = canvas.drawTitleBlock()

        func statsRow(_ label: String, _ items: [ReportItem], clips: [ReportItem]? = nil) -> [CellContent] {
            let s = Stats(items)
            return [.text(label), .text(String(s.clips)), .text(s.durationText), .text(String(s.files)), .text(ReportFormatting.size(s.size)),
                    .bar(Double(s.clips) / Double(totalClips))]
        }
        let statsColumns: (String) -> [TableColumn] = { first in
            [TableColumn(title: first), TableColumn(title: "Clips", alignment: .right), TableColumn(title: "Duration", alignment: .right),
             TableColumn(title: "Files", alignment: .right), TableColumn(title: "Size", alignment: .right, fixedWidth: 72.1),
             TableColumn(title: "Share in Clips", alignment: .right, isBar: true)]
        }

        func box(_ title: String, columns: [TableColumn]? = nil, rows: [[CellContent]] = [], lines: [String] = []) {
            let width = canvas.setup.boxWidth - 11.2 * scale
            var contentHeight: Double
            if let columns {
                contentHeight = canvas.tableHeight(columns: columns, rows: rows, style: st, width: width)
            } else {
                contentHeight = Double(lines.count) * 14.0 * scale
            }
            let boxHeight = columns == nil && lines.isEmpty ? 33.7 * scale : 22.4 * scale + contentHeight + 5.6 * scale
            if boxY + boxHeight > canvas.setup.contentBottom && boxY > canvas.setup.contentTop + 1 {
                canvas.newPage()
                boxY = canvas.setup.contentTop
            }
            canvas.drawBox(y: boxY, height: boxHeight, title: title)
            if let columns {
                canvas.drawTable(columns: columns, rows: rows, style: st, x: canvas.setup.boxLeft + 5.6 * scale, y: boxY + 22.4 * scale, width: width)
            } else {
                var ly = boxY + 22.4 * scale
                for line in lines {
                    canvas.pdf.text(line, x: canvas.setup.boxLeft + 13.3 * scale, top: ly, size: canvas.setup.bodySize, font: .mono)
                    ly += 14.0 * scale
                }
            }
            boxY += boxHeight + 11.2 * scale
        }

        let video = ctx.videoClips, audio = ctx.audioClips, other = ctx.otherFiles
        let clipItems = ctx.allClips

        // (il riquadro «Production Info» è stato tolto su richiesta)

        // Clips Overview
        box("Clips Overview", columns: statsColumns(""), rows: [
            statsRow("Source Video Clips", video), statsRow("Audio Clips", audio), statsRow("Other Files", other),
            statsRow("Transcoded Clips", []), statsRow("Total", ctx.items),
        ])

        // Workflow (funzioni non gestite dall'app: zero per definizione)
        box("Workflow", columns: statsColumns(""), rows: [
            statsRow("With Custom Look", []), statsRow("With External Audio", []), statsRow("With Transcoded Clips", []),
            statsRow("With Remote Resources", []), statsRow("All Video", video),
        ])

        // Labels & Flags
        func iconRow(_ content: CellContent, _ items: [ReportItem]) -> [CellContent] {
            let s = Stats(items)
            return [content, .text(String(s.clips)), .text(s.durationText), .text(String(s.files)), .text(ReportFormatting.size(s.size)),
                    .bar(Double(s.clips) / Double(totalClips))]
        }
        box("Labels & Flags", columns: statsColumns(""), rows: [iconRow(.label("No Label"), clipItems), iconRow(.flag("Flagged"), [])])

        // Ratings: l'app non gestisce le valutazioni, tutti i clip sono a zero stelle
        var ratingRows = (1...5).reversed().map { iconRow(.stars($0), []) }
        ratingRows.append(iconRow(.stars(0), clipItems))
        box("Ratings", columns: statsColumns(""), rows: ratingRows)

        // Backups (Verified): clip per numero di copie verificate; i file contano tutti i file del gruppo
        func bucket(_ n: Int, plus: Bool = false) -> [ReportItem] {
            ctx.items.filter { plus ? $0.verifiedBackups >= n : $0.verifiedBackups == n }
        }
        func backupRow(_ label: String, _ items: [ReportItem]) -> [CellContent] {
            let s = Stats(items)
            return [.text(label), .text(String(s.clips)), .text(s.durationText), .text(String(s.files)), .text(ReportFormatting.size(s.size)),
                    .bar(Double(s.clips) / Double(totalClips))]
        }
        box("Backups", columns: statsColumns("Backups (Verified)"), rows: [
            backupRow("3+", bucket(3, plus: true)), backupRow("2", bucket(2)), backupRow("1", bucket(1)), backupRow("0", bucket(0)),
        ])

        // Bins / Video Reels / Camera Sums / Video Formats / Audio Tapes
        func groups(_ items: [ReportItem], by key: (ReportItem) -> String) -> [(String, [ReportItem])] {
            var order: [String] = [], map: [String: [ReportItem]] = [:]
            for i in items { let k = key(i); if map[k] == nil { order.append(k) }; map[k, default: []].append(i) }
            return order.map { ($0, map[$0]!) }
        }
        func cameras(_ items: [ReportItem]) -> String {
            var seen = Set<String>(), out: [String] = []
            for i in items.filter({ $0.isClip }) { if let c = i.meta("cameraIndex"), seen.insert(c).inserted { out.append(c) } }
            return out.isEmpty ? ClipColumns.reportNotAvailable : out.joined(separator: ", ")
        }
        func groupRow(_ label: String, _ items: [ReportItem]) -> [CellContent] {
            let s = Stats(items)
            return [.text(label), .text(cameras(items)), .text(String(s.clips)), .text(s.durationText), .text(String(s.files)),
                    .text(ReportFormatting.size(s.size)), .bar(Double(s.clips) / Double(totalClips))]
        }
        func groupColumns(_ first: String) -> [TableColumn] {
            [TableColumn(title: first), TableColumn(title: "Camera(s)", alignment: .right), TableColumn(title: "Clips", alignment: .right),
             TableColumn(title: "Duration", alignment: .right, fixedWidth: 72.1), TableColumn(title: "Files", alignment: .right, fixedWidth: 72.1),
             TableColumn(title: "Size", alignment: .right, fixedWidth: 72.1), TableColumn(title: "Share in Clips", alignment: .right, isBar: true)]
        }
        box("Bins", columns: groupColumns("Bin Name"), rows: groups(ctx.items, by: { $0.clip.binName }).map { groupRow($0.0, $0.1) })
        box("Video Reels", columns: groupColumns("Reel Name"),
            rows: groups(video, by: { $0.meta("reel") ?? ClipColumns.reportNotAvailable }).map { groupRow($0.0, $0.1) })

        func reelCount(_ items: [ReportItem]) -> Int { Set(items.map { $0.meta("reel") ?? "" }).count }
        func frameSum(_ items: [ReportItem]) -> String {
            let known = items.compactMap(\.frames)
            return known.isEmpty ? ClipColumns.reportNotAvailable : String(known.reduce(0, +))
        }
        func cameraRow(_ label: String, _ items: [ReportItem]) -> [CellContent] {
            let s = Stats(items)
            return [.text(label), .text(String(reelCount(items))), .text(frameSum(items)), .text(String(s.clips)), .text(s.durationText),
                    .text(String(s.files)), .text(ReportFormatting.size(s.size)), .bar(Double(s.clips) / Double(totalClips))]
        }
        var cameraRows = groups(video, by: { $0.meta("cameraIndex") ?? ClipColumns.reportNotAvailable }).map { cameraRow($0.0, $0.1) }
        cameraRows.append(cameraRow("Total", video))
        box("Camera Sums", columns: [
            TableColumn(title: "Camera"), TableColumn(title: "Reel Count", alignment: .right), TableColumn(title: "Frames", alignment: .right),
            TableColumn(title: "Clips", alignment: .right), TableColumn(title: "Duration", alignment: .right, fixedWidth: 72.1),
            TableColumn(title: "Files", alignment: .right, fixedWidth: 72.1),
            TableColumn(title: "Size", alignment: .right, fixedWidth: 72.1), TableColumn(title: "Share in Clips", alignment: .right, isBar: true),
        ], rows: cameraRows)

        func formatKey(_ i: ReportItem) -> String {
            [i.meta("codec") ?? "", i.fileExtension, i.meta("resolution") ?? "", i.meta("frameRate") ?? ""].joined(separator: "|")
        }
        let formatRows = groups(video, by: formatKey).map { key, items -> [CellContent] in
            let p = key.components(separatedBy: "|")
            let s = Stats(items)
            func v(_ s: String) -> String { s.isEmpty ? ClipColumns.reportNotAvailable : s }
            return [.text(v(p[0])), .text(p[1]), .text(v(p[2])), .text(v(p[3])), .text(String(s.clips)), .text(s.durationText),
                    .text(String(s.files)), .text(ReportFormatting.size(s.size)), .bar(Double(s.clips) / Double(totalClips))]
        }
        box("Video Formats", columns: [
            TableColumn(title: "Codec"), TableColumn(title: "Filetype", alignment: .right), TableColumn(title: "Resolution", alignment: .right),
            TableColumn(title: "FPS", alignment: .right), TableColumn(title: "Clips", alignment: .right), TableColumn(title: "Duration", alignment: .right),
            TableColumn(title: "Files", alignment: .right), TableColumn(title: "Size", alignment: .right),
            TableColumn(title: "Share in Clips", alignment: .right, isBar: true),
        ], rows: formatRows)

        box("Audio Tapes", columns: statsColumns("Tape Name"), rows: [])

        canvas.decoratePages()
        return canvas.pdf.data(title: "\(ctx.kind.title) – \(ctx.title)", author: ctx.operatorName)
    }
}
