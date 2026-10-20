import Foundation

/// Cartella delle anteprime: `clip-<id>.jpg` se riuscita, `clip-<id>.err` con il motivo se non è stato possibile.
public struct ThumbnailCache {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TeoStackXt/Thumbnails", isDirectory: true)
    }

    public func imageURL(clipID: Int64) -> URL { directory.appendingPathComponent("clip-\(clipID).jpg") }
    private func errorURL(clipID: Int64) -> URL { directory.appendingPathComponent("clip-\(clipID).err") }

    public func hasImage(clipID: Int64) -> Bool { FileManager.default.fileExists(atPath: imageURL(clipID: clipID).path) }

    /// Il motivo per cui l'anteprima non c'è (se è stato registrato).
    public func failureReason(clipID: Int64) -> String? {
        try? String(contentsOf: errorURL(clipID: clipID), encoding: .utf8)
    }

    func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func recordFailure(clipID: Int64, reason: String) {
        try? ensureDirectory()
        try? FileManager.default.removeItem(at: imageURL(clipID: clipID))
        try? reason.write(to: errorURL(clipID: clipID), atomically: true, encoding: .utf8)
    }

    func clearFailure(clipID: Int64) {
        try? FileManager.default.removeItem(at: errorURL(clipID: clipID))
    }

    public func remove(clipID: Int64) {
        try? FileManager.default.removeItem(at: imageURL(clipID: clipID))
        clearFailure(clipID: clipID)
    }
}
