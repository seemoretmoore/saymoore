import XCTest
import CryptoKit
@testable import SayMoore

final class ModelDownloaderTests: XCTestCase {

    private var tempDir: URL!
    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("saymoore-md-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        MockURLProtocol.reset()
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    // MARK: - currentStatus

    func testStatusMissingWhenNothingPresent() throws {
        let dl = ModelDownloader(
            remoteURL: URL(string: "https://example.com/m.bin")!,
            destinationURL: tempDir.appendingPathComponent("m.bin"),
            expectedSHA256: "deadbeef",
            session: makeSession()
        )
        XCTAssertEqual(try dl.currentStatus(), .missing)
    }

    func testStatusPartialWhenSentinelPresent() throws {
        let dest = tempDir.appendingPathComponent("m.bin")
        try Data(repeating: 0xAB, count: 128).write(to: dest)
        try Data().write(to: dest.appendingPathExtension("download-in-progress"))

        let dl = ModelDownloader(
            remoteURL: URL(string: "https://example.com/m.bin")!,
            destinationURL: dest,
            expectedSHA256: "deadbeef",
            session: makeSession()
        )
        XCTAssertEqual(try dl.currentStatus(), .partial(bytesOnDisk: 128))
    }

    func testStatusCompleteRequiresVerifiedMarkerMatchingExpectedHash() throws {
        let dest = tempDir.appendingPathComponent("m.bin")
        try Data(repeating: 1, count: 64).write(to: dest)
        let expectedHash = "deadbeef"
        // Marker present and matching → complete.
        try expectedHash.write(
            to: dest.appendingPathExtension("verified"),
            atomically: true,
            encoding: .utf8
        )
        let dl = ModelDownloader(
            remoteURL: URL(string: "https://example.com/m.bin")!,
            destinationURL: dest,
            expectedSHA256: expectedHash,
            session: makeSession()
        )
        XCTAssertEqual(try dl.currentStatus(), .complete)
    }

    func testStatusPartialWhenFileExistsWithoutVerifiedMarker() throws {
        let dest = tempDir.appendingPathComponent("m.bin")
        try Data(repeating: 1, count: 64).write(to: dest)
        // No .verified marker → must NOT trust the file.
        let dl = ModelDownloader(
            remoteURL: URL(string: "https://example.com/m.bin")!,
            destinationURL: dest,
            expectedSHA256: "deadbeef",
            session: makeSession()
        )
        XCTAssertEqual(try dl.currentStatus(), .partial(bytesOnDisk: 64))
    }

    func testStatusPartialWhenVerifiedMarkerHasStaleHash() throws {
        let dest = tempDir.appendingPathComponent("m.bin")
        try Data(repeating: 1, count: 64).write(to: dest)
        // Marker recorded a different (older) expected hash — model upgrade case.
        try "oldhash".write(
            to: dest.appendingPathExtension("verified"),
            atomically: true,
            encoding: .utf8
        )
        let dl = ModelDownloader(
            remoteURL: URL(string: "https://example.com/m.bin")!,
            destinationURL: dest,
            expectedSHA256: "newhash",
            session: makeSession()
        )
        XCTAssertEqual(try dl.currentStatus(), .partial(bytesOnDisk: 64))
    }

    // MARK: - verifyExistingIfPossible (migration)

    func testVerifyExistingWritesMarkerWhenHashMatches() async throws {
        let body = Data(repeating: 0x42, count: 1024)
        let hash = sha256Hex(body)
        let dest = tempDir.appendingPathComponent("m.bin")
        try body.write(to: dest)
        // No marker, no sentinel — pre-marker install case.
        let dl = ModelDownloader(
            remoteURL: URL(string: "https://example.com/m.bin")!,
            destinationURL: dest,
            expectedSHA256: hash,
            session: makeSession()
        )
        XCTAssertEqual(try dl.currentStatus(), .partial(bytesOnDisk: 1024))
        await dl.verifyExistingIfPossible()
        XCTAssertEqual(try dl.currentStatus(), .complete)
        let marker = try String(contentsOf: dest.appendingPathExtension("verified"), encoding: .utf8)
        XCTAssertEqual(marker.trimmingCharacters(in: .whitespacesAndNewlines), hash)
    }

    func testVerifyExistingDoesNothingWhenHashMismatches() async throws {
        let dest = tempDir.appendingPathComponent("m.bin")
        try Data(repeating: 0x99, count: 1024).write(to: dest)
        let dl = ModelDownloader(
            remoteURL: URL(string: "https://example.com/m.bin")!,
            destinationURL: dest,
            expectedSHA256: String(repeating: "a", count: 64),
            session: makeSession()
        )
        await dl.verifyExistingIfPossible()
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dest.appendingPathExtension("verified").path
        ))
        XCTAssertEqual(try dl.currentStatus(), .partial(bytesOnDisk: 1024))
    }

    func testVerifyExistingSkipsWhenSentinelPresent() async throws {
        // Mid-download state must not be promoted to verified by migration.
        let dest = tempDir.appendingPathComponent("m.bin")
        try Data(repeating: 0x42, count: 256).write(to: dest)
        try Data().write(to: dest.appendingPathExtension("download-in-progress"))
        let dl = ModelDownloader(
            remoteURL: URL(string: "https://example.com/m.bin")!,
            destinationURL: dest,
            expectedSHA256: sha256Hex(Data(repeating: 0x42, count: 256)),
            session: makeSession()
        )
        await dl.verifyExistingIfPossible()
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dest.appendingPathExtension("verified").path
        ))
    }

    // MARK: - download

    func testFreshDownloadWritesFileSentinelGoneAndVerifiedMarkerCreated() async throws {
        let body = Data(repeating: 0x42, count: 1024)
        let hash = sha256Hex(body)
        MockURLProtocol.handler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Range"))
            return (HTTPURLResponse.ok(byteCount: body.count), body)
        }
        let dest = tempDir.appendingPathComponent("m.bin")
        let dl = ModelDownloader(
            remoteURL: URL(string: "https://example.com/m.bin")!,
            destinationURL: dest,
            expectedSHA256: hash,
            session: makeSession()
        )

        try await dl.download { _ in }

        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dest.appendingPathExtension("download-in-progress").path
        ))
        XCTAssertEqual(try Data(contentsOf: dest), body)
        let marker = try String(contentsOf: dest.appendingPathExtension("verified"), encoding: .utf8)
        XCTAssertEqual(marker.trimmingCharacters(in: .whitespacesAndNewlines), hash)
        XCTAssertEqual(try dl.currentStatus(), .complete)
    }

    func testResumeAppendsFromExistingByteCount() async throws {
        let firstHalf = Data(repeating: 0xAA, count: 512)
        let secondHalf = Data(repeating: 0xBB, count: 512)
        let full = firstHalf + secondHalf
        let hash = sha256Hex(full)

        // Pre-seed disk with a partial download + sentinel.
        let dest = tempDir.appendingPathComponent("m.bin")
        try firstHalf.write(to: dest)
        try Data().write(to: dest.appendingPathExtension("download-in-progress"))

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=512-")
            // 206 Partial Content with the remaining bytes.
            return (HTTPURLResponse.partial(start: 512, total: 1024), secondHalf)
        }

        let dl = ModelDownloader(
            remoteURL: URL(string: "https://example.com/m.bin")!,
            destinationURL: dest,
            expectedSHA256: hash,
            session: makeSession()
        )

        try await dl.download { _ in }

        XCTAssertEqual(try Data(contentsOf: dest), full)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dest.appendingPathExtension("download-in-progress").path
        ))
    }

    func testSHA256MismatchScrubsFileAndSentinelSoRetryRestartsFromZero() async throws {
        let body = Data(repeating: 0x11, count: 256)
        MockURLProtocol.handler = { _ in
            (HTTPURLResponse.ok(byteCount: body.count), body)
        }
        let dest = tempDir.appendingPathComponent("m.bin")
        let dl = ModelDownloader(
            remoteURL: URL(string: "https://example.com/m.bin")!,
            destinationURL: dest,
            expectedSHA256: "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
            session: makeSession()
        )

        do {
            try await dl.download { _ in }
            XCTFail("expected modelCorrupted")
        } catch SayMooreError.modelCorrupted {
            // F2: file and sentinel must be gone so retry restarts from byte 0.
            let fm = FileManager.default
            XCTAssertFalse(fm.fileExists(atPath: dest.path))
            XCTAssertFalse(fm.fileExists(
                atPath: dest.appendingPathExtension("download-in-progress").path
            ))
            XCTAssertFalse(fm.fileExists(
                atPath: dest.appendingPathExtension("verified").path
            ))
            XCTAssertEqual(try dl.currentStatus(), .missing)
        }
    }

    func testRetryAfterChecksumFailureSucceedsOnSecondAttempt() async throws {
        let body = Data(repeating: 0x42, count: 1024)
        let goodHash = sha256Hex(body)
        let dest = tempDir.appendingPathComponent("m.bin")

        // First downloader expects the wrong hash → must scrub state on failure.
        MockURLProtocol.handler = { _ in
            (HTTPURLResponse.ok(byteCount: body.count), body)
        }
        let badDl = ModelDownloader(
            remoteURL: URL(string: "https://example.com/m.bin")!,
            destinationURL: dest,
            expectedSHA256: String(repeating: "f", count: 64),
            session: makeSession()
        )
        await XCTAssertThrowsErrorAsync(try await badDl.download { _ in })

        // Second downloader with the correct hash and no Range header expected
        // (state was scrubbed, so it's a fresh download).
        MockURLProtocol.handler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Range"))
            return (HTTPURLResponse.ok(byteCount: body.count), body)
        }
        let goodDl = ModelDownloader(
            remoteURL: URL(string: "https://example.com/m.bin")!,
            destinationURL: dest,
            expectedSHA256: goodHash,
            session: makeSession()
        )
        try await goodDl.download { _ in }
        XCTAssertEqual(try Data(contentsOf: dest), body)
        XCTAssertEqual(try goodDl.currentStatus(), .complete)
    }

    func testResumeRequestReceiving200RestartsFromZero() async throws {
        let firstHalf = Data(repeating: 0xAA, count: 512)
        let fullBody = Data(repeating: 0xCC, count: 1024)
        let hash = sha256Hex(fullBody)

        let dest = tempDir.appendingPathComponent("m.bin")
        try firstHalf.write(to: dest)
        try Data().write(to: dest.appendingPathExtension("download-in-progress"))

        // Server ignores Range and returns the full body with 200.
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=512-")
            return (HTTPURLResponse.ok(byteCount: fullBody.count), fullBody)
        }

        let dl = ModelDownloader(
            remoteURL: URL(string: "https://example.com/m.bin")!,
            destinationURL: dest,
            expectedSHA256: hash,
            session: makeSession()
        )
        try await dl.download { _ in }

        // Must not be 1.5KB of appended garbage — must be the full 1KB body.
        XCTAssertEqual(try Data(contentsOf: dest), fullBody)
    }

    func testResumeRequestWithMismatchedContentRangeRestartsFromZero() async throws {
        let firstHalf = Data(repeating: 0xAA, count: 512)
        let fullBody = Data(repeating: 0xDD, count: 1024)
        let hash = sha256Hex(fullBody)

        let dest = tempDir.appendingPathComponent("m.bin")
        try firstHalf.write(to: dest)
        try Data().write(to: dest.appendingPathExtension("download-in-progress"))

        // Server returns 206 but starting at 0 instead of the requested 512.
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=512-")
            return (HTTPURLResponse.partial(start: 0, total: 1024), fullBody)
        }

        let dl = ModelDownloader(
            remoteURL: URL(string: "https://example.com/m.bin")!,
            destinationURL: dest,
            expectedSHA256: hash,
            session: makeSession()
        )
        try await dl.download { _ in }

        XCTAssertEqual(try Data(contentsOf: dest), fullBody)
    }

    func testProgressCallbackReceivesFractionsBetweenZeroAndOne() async throws {
        let body = Data(repeating: 0x77, count: 4096)
        let hash = sha256Hex(body)
        MockURLProtocol.handler = { _ in
            (HTTPURLResponse.ok(byteCount: body.count), body)
        }
        let dest = tempDir.appendingPathComponent("m.bin")
        let dl = ModelDownloader(
            remoteURL: URL(string: "https://example.com/m.bin")!,
            destinationURL: dest,
            expectedSHA256: hash,
            session: makeSession()
        )

        final class FractionsBox: @unchecked Sendable {
            var values: [Double] = []
            let lock = NSLock()
            func append(_ f: Double) { lock.lock(); values.append(f); lock.unlock() }
        }
        let box = FractionsBox()
        try await dl.download { f in box.append(f) }
        XCTAssertFalse(box.values.isEmpty)
        XCTAssertTrue(box.values.allSatisfy { $0 >= 0.0 && $0 <= 1.0 })
        XCTAssertEqual(box.values.last ?? -1, 1.0, accuracy: 0.0001)
    }
}

// Async XCTAssertThrowsError helper.
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch {
        // ok
    }
}

// MARK: - URLProtocol mock

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?
    static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        handler = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let h = Self.handler
        Self.lock.unlock()
        guard let h else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (resp, data) = h(request)
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension HTTPURLResponse {
    static func ok(byteCount: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://example.com/m.bin")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "\(byteCount)"]
        )!
    }
    static func partial(start: Int, total: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://example.com/m.bin")!,
            statusCode: 206,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Length": "\(total - start)",
                "Content-Range": "bytes \(start)-\(total - 1)/\(total)",
            ]
        )!
    }
}
