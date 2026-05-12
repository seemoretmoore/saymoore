import Foundation
import CryptoKit

enum ModelDownloaderStatus: Equatable {
    case missing
    case partial(bytesOnDisk: Int)
    case complete
}

protocol ModelDownloading: Sendable {
    func currentStatus() throws -> ModelDownloaderStatus
    func download(progress: @escaping @Sendable (Double) -> Void) async throws
    /// Migration: if a model file from a pre-marker build is on disk and
    /// hashes to the expected value, write the .verified marker so warm
    /// launches don't trigger a needless re-download.
    func verifyExistingIfPossible() async
}

final class ModelDownloader: ModelDownloading, @unchecked Sendable {
    let remoteURL: URL
    let destinationURL: URL
    let expectedSHA256: String
    let session: URLSession

    var sentinelURL: URL { destinationURL.appendingPathExtension("download-in-progress") }
    var verifiedMarkerURL: URL { destinationURL.appendingPathExtension("verified") }

    init(
        remoteURL: URL,
        destinationURL: URL,
        expectedSHA256: String,
        session: URLSession = .shared
    ) {
        self.remoteURL = remoteURL
        self.destinationURL = destinationURL
        self.expectedSHA256 = expectedSHA256.lowercased()
        self.session = session
    }

    func currentStatus() throws -> ModelDownloaderStatus {
        let fm = FileManager.default
        let hasFile = fm.fileExists(atPath: destinationURL.path)
        let hasSentinel = fm.fileExists(atPath: sentinelURL.path)
        if !hasFile && !hasSentinel { return .missing }
        if hasSentinel {
            let size: Int
            if hasFile {
                let attrs = try fm.attributesOfItem(atPath: destinationURL.path)
                size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            } else {
                size = 0
            }
            return .partial(bytesOnDisk: size)
        }
        // hasFile && !hasSentinel — only trust as complete if a valid
        // .verified marker exists matching the currently-expected hash.
        if let marker = try? String(contentsOf: verifiedMarkerURL, encoding: .utf8),
           marker.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == expectedSHA256 {
            return .complete
        }
        // Marker missing or stale (e.g. expected hash changed). Force the
        // bootstrap to re-enter the download path; F2/F3 self-heal if bytes
        // are wrong.
        let attrs = try fm.attributesOfItem(atPath: destinationURL.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        return .partial(bytesOnDisk: size)
    }

    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        let dir = destinationURL.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // A stale .verified marker would lie to currentStatus() if we crashed
        // mid-download; clear it before touching bytes.
        try? fm.removeItem(at: verifiedMarkerURL)

        if !fm.fileExists(atPath: sentinelURL.path) {
            try Data().write(to: sentinelURL)
        }

        var existing: Int = {
            guard fm.fileExists(atPath: destinationURL.path),
                  let attrs = try? fm.attributesOfItem(atPath: destinationURL.path),
                  let n = (attrs[.size] as? NSNumber)?.intValue else { return 0 }
            return n
        }()

        var req = URLRequest(url: remoteURL)
        if existing > 0 { req.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }

        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        // F3: if we asked for a range, the server MUST respond with 206 and
        // a Content-Range that picks up exactly where we left off. Otherwise
        // discard the partial bytes and treat the body as a fresh download.
        var appendMode = existing > 0
        if existing > 0 {
            let rangeOK: Bool = {
                guard http.statusCode == 206,
                      let cr = http.value(forHTTPHeaderField: "Content-Range") else {
                    return false
                }
                // Format: "bytes <start>-<end>/<total>"
                let trimmed = cr.replacingOccurrences(of: "bytes ", with: "")
                guard let dash = trimmed.firstIndex(of: "-") else { return false }
                let startStr = String(trimmed[..<dash])
                guard let start = Int(startStr) else { return false }
                return start == existing
            }()
            if !rangeOK {
                Log.model.info("server ignored Range or returned wrong start; restarting from 0")
                appendMode = false
                existing = 0
                if fm.fileExists(atPath: destinationURL.path) {
                    try? fm.removeItem(at: destinationURL)
                }
            }
        }

        let totalBytes: Int = {
            if http.statusCode == 206, let cr = http.value(forHTTPHeaderField: "Content-Range") {
                if let last = cr.split(separator: "/").last, let n = Int(last) { return n }
            }
            let cl = http.expectedContentLength
            if cl > 0 { return existing + Int(cl) }
            return 0
        }()

        if !fm.fileExists(atPath: destinationURL.path) {
            fm.createFile(atPath: destinationURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: destinationURL)
        if appendMode {
            try handle.seekToEnd()
        } else {
            try handle.seek(toOffset: 0)
            try handle.truncate(atOffset: 0)
        }

        var written = existing
        var chunk = Data()
        chunk.reserveCapacity(64 * 1024)
        for try await byte in bytes {
            chunk.append(byte)
            if chunk.count >= 64 * 1024 {
                try handle.write(contentsOf: chunk)
                written += chunk.count
                chunk.removeAll(keepingCapacity: true)
                if totalBytes > 0 {
                    progress(min(1.0, Double(written) / Double(totalBytes)))
                }
            }
        }
        if !chunk.isEmpty {
            try handle.write(contentsOf: chunk)
            written += chunk.count
        }
        try handle.close()
        if totalBytes > 0 {
            progress(min(1.0, Double(written) / Double(totalBytes)))
        }

        let actual = try sha256Hex(of: destinationURL)
        if actual != expectedSHA256 {
            Log.model.error("SHA256 mismatch: expected=\(self.expectedSHA256, privacy: .public) actual=\(actual, privacy: .public)")
            // F2: scrub local state so the next retry restarts from byte 0
            // instead of looping on a corrupt full-size file.
            try? fm.removeItem(at: destinationURL)
            try? fm.removeItem(at: sentinelURL)
            throw SayMooreError.modelCorrupted
        }

        // F1: persist the verified hash so warm launches can trust the file
        // without re-hashing every startup, and reject it on model upgrade.
        try expectedSHA256.write(to: verifiedMarkerURL, atomically: true, encoding: .utf8)
        try? fm.removeItem(at: sentinelURL)
        Log.model.info("model verified ok (\(written, privacy: .public) bytes)")
    }

    func verifyExistingIfPossible() async {
        let fm = FileManager.default
        // Only run for the pre-marker case: file present, no in-progress
        // sentinel, no (or stale) marker. Anything else is already handled
        // by currentStatus() / the normal download path.
        guard fm.fileExists(atPath: destinationURL.path),
              !fm.fileExists(atPath: sentinelURL.path) else { return }
        if let marker = try? String(contentsOf: verifiedMarkerURL, encoding: .utf8),
           marker.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == expectedSHA256 {
            return
        }
        do {
            let actual = try sha256Hex(of: destinationURL)
            if actual == expectedSHA256 {
                try expectedSHA256.write(
                    to: verifiedMarkerURL,
                    atomically: true,
                    encoding: .utf8
                )
                Log.model.info("migrated existing model to verified marker")
            } else {
                Log.model.info("existing model hash does not match; will re-download")
            }
        } catch {
            Log.model.error("verifyExistingIfPossible failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
