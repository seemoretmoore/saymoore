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

    /// Remove every file under `dir`. Intended for Release-build launch as
    /// belt-and-braces against orphan WAVs left by prior Debug sessions on a
    /// machine that has switched to a Release-signed daily build. No-op if the
    /// directory does not exist. Tolerates partial failures (logged, swallowed).
    static func purgeAll(in dir: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return }
        let contents = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for url in contents {
            try? fm.removeItem(at: url)
        }
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
