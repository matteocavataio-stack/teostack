import Foundation

public enum ReportSection: String, CaseIterable, Identifiable, Codable {
    case shootingDay, clips, volume, productionInfo, clipsOverview, cameraSummary, videoFormats, notes

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .shootingDay: return "Shooting Day"
        case .clips: return "Clips"
        case .volume: return "Volume"
        case .productionInfo: return "Production Info"
        case .clipsOverview: return "Clips Overview"
        case .cameraSummary: return "Camera Summary"
        case .videoFormats: return "Video Formats"
        case .notes: return "Note"
        }
    }

    /// Le tre sezioni principali del report; le altre sono riepiloghi opzionali.
    public var isOptionalSummary: Bool {
        switch self {
        case .shootingDay, .clips, .volume: return false
        default: return true
        }
    }
}

public struct ReportOptions {
    public var projectName: String
    public var operatorName: String
    public var notes: String
    public var sections: Set<ReportSection>
    public var clipColumnIDs: [String]
    public var generatedAt: Date

    public init(projectName: String, operatorName: String = "", notes: String = "",
                sections: Set<ReportSection> = [.shootingDay, .clips, .volume],
                clipColumnIDs: [String] = ClipColumns.defaultVisibleIDs, generatedAt: Date = Date()) {
        self.projectName = projectName
        self.operatorName = operatorName
        self.notes = notes
        self.sections = sections
        self.clipColumnIDs = clipColumnIDs
        self.generatedAt = generatedAt
    }
}

/// Cella di tabella: il testo mostrato nel report.
public struct ReportCell: Equatable {
    public var display: String

    public init(_ display: String) {
        self.display = display
    }
}

public enum ReportAlignment { case left, right }

public struct ReportColumn: Equatable {
    public var id: String
    public var title: String
    public var width: Double          // peso relativo
    public var alignment: ReportAlignment

    public init(id: String, title: String, width: Double = 1, alignment: ReportAlignment = .left) {
        self.id = id
        self.title = title
        self.width = width
        self.alignment = alignment
    }
}

public struct ReportTable: Equatable {
    public var columns: [ReportColumn]
    public var rows: [[ReportCell]]
    public var footer: [ReportCell]?

    public init(columns: [ReportColumn], rows: [[ReportCell]], footer: [ReportCell]? = nil) {
        self.columns = columns
        self.rows = rows
        self.footer = footer
    }
}

public enum ReportContent: Equatable {
    case table(ReportTable)
    case keyValues([(String, String)])
    case text(String)

    public static func == (a: ReportContent, b: ReportContent) -> Bool {
        switch (a, b) {
        case (.table(let x), .table(let y)): return x == y
        case (.text(let x), .text(let y)): return x == y
        case (.keyValues(let x), .keyValues(let y)): return x.elementsEqual(y) { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }
}

public struct ReportBlock: Equatable {
    public var section: ReportSection
    public var title: String
    public var subtitle: String?
    public var content: ReportContent

    public init(section: ReportSection, title: String, subtitle: String? = nil, content: ReportContent) {
        self.section = section
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }
}

public struct ReportDocument: Equatable {
    public var title: String
    public var template: String
    public var meta: [(String, String)]
    public var blocks: [ReportBlock]

    public static func == (a: ReportDocument, b: ReportDocument) -> Bool {
        a.title == b.title && a.template == b.template && a.blocks == b.blocks && a.meta.elementsEqual(b.meta) { $0.0 == $1.0 && $0.1 == $1.1 }
    }
}
