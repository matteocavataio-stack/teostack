import Foundation

/// Crea i PDF dei report a partire dal database.
public enum ReportGenerator {
    public struct Output {
        public var kind: ReportKind
        public var fileName: String
        public var data: Data
    }

    public static func generate(_ kind: ReportKind, store: ProjectStore, projectID: Int64, nodeID: Int64,
                                options: ReportOptions, thumbnails: ThumbnailCache?) throws -> Output {
        let ctx = try ReportContextBuilder.build(kind: kind, store: store, projectID: projectID, nodeID: nodeID,
                                                 options: options, thumbnails: thumbnails)
        let data: Data
        switch kind {
        case .shootingDay: data = ShootingDayReport.render(ctx)
        case .volume: data = VolumeReport.render(ctx)
        case .thumbnail: data = ThumbnailReport.render(ctx)
        case .contactPrint: data = ContactPrintReport.render(ctx)
        case .clips: data = ClipsReport.render(ctx)
        }
        return Output(kind: kind, fileName: kind.fileName(scopeName: ctx.title, date: options.generatedAt), data: data)
    }
}
