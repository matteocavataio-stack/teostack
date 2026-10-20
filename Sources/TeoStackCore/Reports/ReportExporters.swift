import Foundation

/// Esportazione del documento del report nei formati testuali: HTML, CSV, JSON, XML. (PDF: `ReportPDF`; ASC MHL: `ASCMHL`.)
public enum ReportExporter {
    // MARK: HTML (template "Classic")

    public static func html(_ doc: ReportDocument) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        var h = """
        <!DOCTYPE html>
        <html lang="it">
        <head>
        <meta charset="utf-8">
        <title>\(esc(doc.title)) – \(esc(doc.meta.first { $0.0 == "Progetto" }?.1 ?? ""))</title>
        <style>
        body { font-family: -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif; font-size: 12px; color: #222; margin: 24px; }
        h1 { font-size: 22px; margin: 0 0 4px 0; }
        h2 { font-size: 15px; margin: 26px 0 2px 0; padding: 4px 8px; background: #2b3a4a; color: #fff; }
        .sub { color: #666; font-size: 11px; margin: 2px 0 6px 0; }
        table { border-collapse: collapse; width: 100%; margin-top: 4px; }
        th { text-align: left; background: #e3e8ee; border: 1px solid #c4ccd6; padding: 4px 6px; }
        td { border: 1px solid #d5dbe2; padding: 3px 6px; vertical-align: top; }
        tr:nth-child(even) td { background: #f6f8fa; }
        td.r, th.r { text-align: right; }
        tfoot td { font-weight: bold; background: #e3e8ee !important; }
        table.meta td { border: none; padding: 1px 12px 1px 0; background: none !important; }
        table.meta td:first-child { color: #666; width: 140px; }
        pre { white-space: pre-wrap; font-family: inherit; }
        @media print { body { margin: 8mm; } h2 { break-after: avoid; } tr { break-inside: avoid; } }
        </style>
        </head>
        <body>
        <h1>\(esc(doc.title))</h1>
        <div class="sub">Template \(esc(doc.template))</div>
        <table class="meta">
        """
        for (k, v) in doc.meta { h += "<tr><td>\(esc(k))</td><td>\(esc(v))</td></tr>\n" }
        h += "</table>\n"
        for b in doc.blocks {
            h += "<h2>\(esc(b.title))</h2>\n"
            if let s = b.subtitle { h += "<div class=\"sub\">\(esc(s))</div>\n" }
            switch b.content {
            case .text(let t): h += "<pre>\(esc(t))</pre>\n"
            case .keyValues(let items):
                h += "<table class=\"meta\">\n"
                for (k, v) in items { h += "<tr><td>\(esc(k))</td><td>\(esc(v))</td></tr>\n" }
                h += "</table>\n"
            case .table(let t):
                h += "<table>\n<thead><tr>" + t.columns.map { "<th class=\"\($0.alignment == .right ? "r" : "")\">\(esc($0.title))</th>" }.joined() + "</tr></thead>\n<tbody>\n"
                for row in t.rows {
                    h += "<tr>" + zip(row, t.columns).map { "<td class=\"\($0.1.alignment == .right ? "r" : "")\">\(esc($0.0.display))</td>" }.joined() + "</tr>\n"
                }
                h += "</tbody>\n"
                if let f = t.footer {
                    h += "<tfoot><tr>" + zip(f, t.columns).map { "<td class=\"\($0.1.alignment == .right ? "r" : "")\">\(esc($0.0.display))</td>" }.joined() + "</tr></tfoot>\n"
                }
                h += "</table>\n"
            }
        }
        h += "</body>\n</html>\n"
        return h
    }

    // MARK: CSV

    /// UTF-8 con BOM (Excel legge gli accenti). Ogni sezione è preceduta dal suo titolo e separata da una riga vuota.
    public static func csv(_ doc: ReportDocument, delimiter: Character = ";") -> Data {
        func field(_ s: String) -> String {
            let needsQuotes = s.contains(delimiter) || s.contains("\"") || s.contains("\n") || s.contains("\r")
            return needsQuotes ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        func line(_ cells: [String]) -> String { cells.map(field).joined(separator: String(delimiter)) + "\r\n" }
        var out = line([doc.title + " (" + doc.template + ")"])
        for (k, v) in doc.meta { out += line([k, v]) }
        out += "\r\n"
        for b in doc.blocks {
            out += line([b.title] + (b.subtitle.map { [$0] } ?? []))
            switch b.content {
            case .text(let t): out += line([t])
            case .keyValues(let items):
                out += line(["Campo", "Valore"])
                for (k, v) in items { out += line([k, v]) }
            case .table(let t):
                out += line(t.columns.map(\.title))
                for r in t.rows { out += line(r.map(\.machine)) }
                if let f = t.footer { out += line(f.map(\.machine)) }
            }
            out += "\r\n"
        }
        return Data([0xEF, 0xBB, 0xBF]) + Data(out.utf8)
    }

    // MARK: JSON

    public static func json(_ doc: ReportDocument) throws -> Data {
        var sections: [[String: Any]] = []
        for b in doc.blocks {
            var s: [String: Any] = ["id": b.section.rawValue, "title": b.title]
            if let sub = b.subtitle { s["subtitle"] = sub }
            switch b.content {
            case .text(let t):
                s["type"] = "text"; s["text"] = t
            case .keyValues(let items):
                s["type"] = "keyValues"; s["items"] = items.map { ["label": $0.0, "value": $0.1] }
            case .table(let t):
                s["type"] = "table"
                s["columns"] = t.columns.map { ["id": $0.id, "title": $0.title] }
                func object(_ cells: [ReportCell]) -> [String: String] {
                    var o: [String: String] = [:]
                    for (c, col) in zip(cells, t.columns) { o[col.id] = c.machine }
                    return o
                }
                s["rows"] = t.rows.map(object)
                if let f = t.footer { s["footer"] = object(f) }
            }
            sections.append(s)
        }
        var meta: [String: String] = [:]
        for (k, v) in doc.meta { meta[k] = v }
        let root: [String: Any] = ["report": ["title": doc.title, "template": doc.template, "meta": meta,
                                              "metaOrder": doc.meta.map { $0.0 }, "sections": sections]]
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: XML

    static func xmlEscape(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\t", "\n", "\r": out.unicodeScalars.append(u)
            default:
                if u.value >= 0x20 && u.value != 0xFFFE && u.value != 0xFFFF { out.unicodeScalars.append(u) }   // niente caratteri vietati da XML 1.0
            }
        }
        return out
    }

    public static func xml(_ doc: ReportDocument) -> Data {
        let e = xmlEscape
        var x = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<report template=\"\(e(doc.template))\">\n  <title>\(e(doc.title))</title>\n  <meta>\n"
        for (k, v) in doc.meta { x += "    <item label=\"\(e(k))\">\(e(v))</item>\n" }
        x += "  </meta>\n"
        for b in doc.blocks {
            x += "  <section id=\"\(b.section.rawValue)\" title=\"\(e(b.title))\"" + (b.subtitle.map { " subtitle=\"\(e($0))\"" } ?? "") + ">\n"
            switch b.content {
            case .text(let t): x += "    <text>\(e(t))</text>\n"
            case .keyValues(let items):
                for (k, v) in items { x += "    <item label=\"\(e(k))\">\(e(v))</item>\n" }
            case .table(let t):
                x += "    <table>\n      <columns>\n"
                for c in t.columns { x += "        <column id=\"\(e(c.id))\">\(e(c.title))</column>\n" }
                x += "      </columns>\n      <rows>\n"
                func row(_ cells: [ReportCell], _ tag: String) -> String {
                    "        <\(tag)>" + zip(cells, t.columns).map { "<cell column=\"\(e($0.1.id))\">\(e($0.0.machine))</cell>" }.joined() + "</\(tag)>\n"
                }
                for r in t.rows { x += row(r, "row") }
                x += "      </rows>\n"
                if let f = t.footer { x += "      <footer>\n" + row(f, "row") + "      </footer>\n" }
                x += "    </table>\n"
            }
            x += "  </section>\n"
        }
        x += "</report>\n"
        return Data(x.utf8)
    }
}
