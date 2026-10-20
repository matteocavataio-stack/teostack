import XCTest
@testable import TeoStackCore

/// Scenario di prova con la stessa struttura dei report di riferimento: un bin con 2 clip ARRIRAW MXF e 2 file ALE/BIN,
/// offload da una scheda a un disco di destinazione. (Nomi, valori e hash sono di prova.)
struct ReferenceScenario {
    var projectName = "TEST_PROJECT"
    var binName = "A_9001_1C3S"
    var sourceVolume = "A_9001_1C3S"
    var destination = "/Volumes/SSD_8TB_01/TEST_PROVINI/A_9001_1C3S"
    var started: Date

    struct File { var name: String; var size: Int64; var hash: String; var modified: Date; var metadata: [String: String] }

    var files: [File]
    let store: ProjectStore
    let project: Project
    let bin: TreeNode
    let day: TreeNode

    static func date(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "dd/MM/yyyy HH:mm"
        return f.date(from: s)!
    }

    static func clipMetadata(frames: Int, timecode: String, created: String) -> [String: String] {
        ["durationSeconds": String(format: "%.3f", Double(frames) / 25), "frameRate": "25", "codec": "ARRIRAW (13bit)", "resolution": "4608x3164",
         "camera": "ARRI ALEXA 35", "manufacturer": "ARRI", "cameraSerial": "62344", "firmware": "2.02.00", "iso": "800",
         "whiteBalance": "5600 K", "tint": "0", "shutter": "1/50", "sensorFPS": "25", "lookInfo": "90s_v1.alf4c", "tilt": "-0.2", "roll": "-0.7",
         "timecode": timecode, "createDate": created, "cameraIndex": "A_", "reel": "A_9001_1C3S", "colorSpace": "AWG4 / LogC4",
         "lens": "ARRI SZ65-300 T2.8", "focalLength": "65 mm", "ndFilter": "ND 1.2"]
    }

    init(projectName: String = "TEST_PROJECT") throws {
        self.projectName = projectName
        started = ReferenceScenario.date("06/06/2025 10:36")
        let modified = ReferenceScenario.date("06/06/2025 11:36")
        files = [
            File(name: "A_9001C001_250606_093620_a1C3S.mxf", size: 7_840_000_000, hash: "266c70788d229207", modified: modified,
                 metadata: ReferenceScenario.clipMetadata(frames: 328, timecode: "00:45:08:02", created: "2025-06-06 09:36:20")),
            File(name: "A_9001C002_250606_093639_a1C3S.mxf", size: 12_930_000_000, hash: "bbc6d8956c10d44b", modified: modified,
                 metadata: ReferenceScenario.clipMetadata(frames: 542, timecode: "00:45:34:00", created: "2025-06-06 09:36:39")),
            File(name: "A_9001_1C3S_AVID.ale", size: 1_590, hash: "f7f3950a4f9fa27a", modified: modified, metadata: [:]),
            File(name: "A_9001_1C3S_BIN.bin", size: 2_430, hash: "a237df2ebc6d1412", modified: modified, metadata: [:]),
        ]
        store = try ProjectStore(path: nil)
        project = try store.createProject(name: projectName)
        day = try store.createDay(projectID: project.id, name: "DAY01")
        bin = try store.createBin(dayID: day.id, name: binName)
        let source = URL(fileURLWithPath: "/Volumes/\(sourceVolume)/\(binName)")
        let job = OffloadJob(sourceURL: source, destinationRoots: [URL(fileURLWithPath: destination)])
        try store.beginOffload(jobID: job.id, binID: bin.id, sourcePath: source.path, destinations: [destination], startedAt: started)
        let results = files.map { f in
            FileResult(relativePath: f.name, size: f.size, sourceHash: f.hash,
                       destinations: [DestFileResult(status: .ok, destHash: f.hash, message: nil)], modificationDate: f.modified)
        }
        try store.finishOffload(OffloadResult(job: job, outcome: .completed, files: results, preflightErrors: [], destinationErrors: [nil],
                                              skippedAlreadyVerified: 0, elapsed: 60), finishedAt: started.addingTimeInterval(60))
        for clip in try store.clips(underNode: bin.id, mediaOnly: false) {
            if let f = files.first(where: { $0.name == clip.name }), !f.metadata.isEmpty {
                try store.updateMetadata(clipID: clip.id, merging: f.metadata)
            }
        }
    }

    func context(_ kind: ReportKind, thumbnails: ThumbnailCache? = nil, operatorName: String = "", notes: String = "") throws -> ReportContext {
        try ReportContextBuilder.build(kind: kind, store: store, projectID: project.id, nodeID: bin.id,
                                       options: ReportOptions(projectName: projectName, operatorName: operatorName, notes: notes,
                                                              generatedAt: ReferenceScenario.date("20/10/2026 14:55")),
                                       thumbnails: thumbnails)
    }
}
