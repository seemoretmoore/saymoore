import Foundation

enum RecordingPaths {
    static func defaultDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("SayMoore/recordings", isDirectory: true)
    }

    @discardableResult
    static func ensureDirectory(at url: URL) throws -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        }
        try fm.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: url.path
        )
        return url
    }

    static func newRecordingURL(in dir: URL) -> URL {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        let stamp = f.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let name = "rec-\(stamp)-\(UUID().uuidString.prefix(8)).wav"
        return dir.appendingPathComponent(name, isDirectory: false)
    }
}
