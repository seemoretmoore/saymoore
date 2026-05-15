import XCTest
@testable import SayMoore

final class OllamaTrustProbeTests: XCTestCase {

    // MARK: - Helpers

    private func makeSession(responding data: Data, statusCode: Int = 200) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OllamaMockURLProtocol.self]
        OllamaMockURLProtocol.handler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "http://127.0.0.1:11434/api/version")!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (data, response)
        }
        return URLSession(configuration: config)
    }

    private func makeSession(error: Error) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OllamaMockURLProtocol.self]
        OllamaMockURLProtocol.handler = { _ in throw error }
        return URLSession(configuration: config)
    }

    private func ollamaLsof(pid: Int32 = 12345) -> String {
        "p\(pid)\nn127.0.0.1:11434"
    }

    /// lsof output with multiple PIDs.
    private func ollamaLsofMultiple(pids: [Int32]) -> String {
        pids.map { "p\($0)\nn127.0.0.1:11434" }.joined(separator: "\n")
    }

    // MARK: - Version endpoint + known-good binary

    func testTrustedResultWithValidJSONAndKnownOllamaApp() async throws {
        let data = try XCTUnwrap(#"{"version":"0.1.32"}"#.data(using: .utf8))
        let session = makeSession(responding: data)
        let lsof = ollamaLsof(pid: 42)
        let probe = OllamaTrustProbe(
            session: session,
            lsofRunner: { lsof },
            binaryPathResolver: { _ in "/Applications/Ollama.app/Contents/MacOS/ollama" }
        )
        let result = await probe.probe()
        guard case .trusted = result else {
            return XCTFail("expected .trusted, got \(result)")
        }
    }

    func testTrustedResultWithHomebrewBinary() async throws {
        let data = try XCTUnwrap(#"{"version":"0.1.32"}"#.data(using: .utf8))
        let session = makeSession(responding: data)
        let lsof = ollamaLsof(pid: 99)
        let probe = OllamaTrustProbe(
            session: session,
            lsofRunner: { lsof },
            binaryPathResolver: { _ in "/opt/homebrew/bin/ollama" }
        )
        let result = await probe.probe()
        guard case .trusted = result else {
            return XCTFail("expected .trusted for homebrew binary, got \(result)")
        }
    }

    // MARK: - HTML response → untrusted

    func testUntrustedEndpointWhenVersionResponseIsHTML() async throws {
        let data = try XCTUnwrap("<html>error</html>".data(using: .utf8))
        let session = makeSession(responding: data)
        let lsof = ollamaLsof()
        let probe = OllamaTrustProbe(
            session: session,
            lsofRunner: { lsof },
            binaryPathResolver: { _ in "/Applications/Ollama.app/Contents/MacOS/ollama" }
        )
        let result = await probe.probe()
        guard case .untrustedEndpoint = result else {
            return XCTFail("expected .untrustedEndpoint, got \(result)")
        }
    }

    func testUntrustedEndpointWhenVersionKeyMissing() async throws {
        let data = try XCTUnwrap(#"{"status":"ok"}"#.data(using: .utf8))
        let session = makeSession(responding: data)
        let lsof = ollamaLsof()
        let probe = OllamaTrustProbe(
            session: session,
            lsofRunner: { lsof },
            binaryPathResolver: { _ in "/Applications/Ollama.app/Contents/MacOS/ollama" }
        )
        let result = await probe.probe()
        guard case .untrustedEndpoint = result else {
            return XCTFail("expected .untrustedEndpoint, got \(result)")
        }
    }

    // MARK: - M4: HTTP failure → fail-closed (untrusted), lsof NOT called

    /// M4: network failure short-circuits to .untrustedEndpoint without running lsof.
    func testNetworkFailureShortCircuitsToUntrustedWithoutCallingLsof() async throws {
        let session = makeSession(error: URLError(.timedOut))
        var lsofCalled = false
        let probe = OllamaTrustProbe(
            session: session,
            lsofRunner: {
                lsofCalled = true
                return "p42\nn127.0.0.1:11434"
            },
            binaryPathResolver: { _ in "/Applications/Ollama.app/Contents/MacOS/ollama" }
        )
        let result = await probe.probe()
        guard case .untrustedEndpoint = result else {
            return XCTFail("expected .untrustedEndpoint on network error, got \(result)")
        }
        XCTAssertFalse(lsofCalled, "lsof must not be called when HTTP check fails")
    }

    /// M4: connection refused (cannotConnectToHost) → untrusted, no lsof.
    func testConnectionRefusedShortCircuitsToUntrusted() async throws {
        let session = makeSession(error: URLError(.cannotConnectToHost))
        var lsofCalled = false
        let probe = OllamaTrustProbe(
            session: session,
            lsofRunner: {
                lsofCalled = true
                return nil
            },
            binaryPathResolver: { _ in nil }
        )
        let result = await probe.probe()
        guard case .untrustedEndpoint = result else {
            return XCTFail("expected .untrustedEndpoint on connection refused, got \(result)")
        }
        XCTAssertFalse(lsofCalled, "lsof must not be called when HTTP check fails")
    }

    // MARK: - Unknown binary → untrusted

    func testUntrustedEndpointWhenLsofReturnsUnknownBinary() async throws {
        let data = try XCTUnwrap(#"{"version":"0.1.32"}"#.data(using: .utf8))
        let session = makeSession(responding: data)
        let lsof = ollamaLsof(pid: 9999)
        let probe = OllamaTrustProbe(
            session: session,
            lsofRunner: { lsof },
            binaryPathResolver: { _ in "/usr/bin/some-other-service" }
        )
        let result = await probe.probe()
        guard case .untrustedEndpoint = result else {
            return XCTFail("expected .untrustedEndpoint, got \(result)")
        }
    }

    // MARK: - Empty lsof output → untrusted

    func testUntrustedEndpointWhenLsofOutputEmpty() async throws {
        let data = try XCTUnwrap(#"{"version":"0.1.32"}"#.data(using: .utf8))
        let session = makeSession(responding: data)
        let probe = OllamaTrustProbe(
            session: session,
            lsofRunner: { "" },
            binaryPathResolver: { _ in nil }
        )
        let result = await probe.probe()
        guard case .untrustedEndpoint = result else {
            return XCTFail("expected .untrustedEndpoint, got \(result)")
        }
    }

    // MARK: - M1: All PIDs must pass

    /// M1: multi-PID lsof output where every PID is trusted → .trusted.
    func testAllPIDsTrustedReturnsTrusted() async throws {
        let data = try XCTUnwrap(#"{"version":"0.1.32"}"#.data(using: .utf8))
        let session = makeSession(responding: data)
        let lsof = ollamaLsofMultiple(pids: [10, 11])
        let probe = OllamaTrustProbe(
            session: session,
            lsofRunner: { lsof },
            binaryPathResolver: { _ in "/Applications/Ollama.app/Contents/MacOS/ollama" }
        )
        let result = await probe.probe()
        guard case .trusted = result else {
            return XCTFail("expected .trusted when all PIDs trusted, got \(result)")
        }
    }

    /// M1: multi-PID lsof output where one PID is rogue → .untrustedEndpoint.
    func testRoguePIDAmongTrustedPIDsReturnsUntrusted() async throws {
        let data = try XCTUnwrap(#"{"version":"0.1.32"}"#.data(using: .utf8))
        let session = makeSession(responding: data)
        // pids 10 and 11 present; pid 11 will resolve to a rogue path
        let lsof = ollamaLsofMultiple(pids: [10, 11])
        let probe = OllamaTrustProbe(
            session: session,
            lsofRunner: { lsof },
            binaryPathResolver: { pid in
                pid == 10 ? "/Applications/Ollama.app/Contents/MacOS/ollama" : "/usr/bin/nc"
            }
        )
        let result = await probe.probe()
        guard case .untrustedEndpoint = result else {
            return XCTFail("expected .untrustedEndpoint when one PID is rogue, got \(result)")
        }
    }

    /// M1: single PID that cannot be resolved (nil path) → .untrustedEndpoint.
    func testUnresolvablePIDReturnsUntrusted() async throws {
        let data = try XCTUnwrap(#"{"version":"0.1.32"}"#.data(using: .utf8))
        let session = makeSession(responding: data)
        let lsof = ollamaLsof(pid: 42)
        let probe = OllamaTrustProbe(
            session: session,
            lsofRunner: { lsof },
            binaryPathResolver: { _ in nil }
        )
        let result = await probe.probe()
        guard case .untrustedEndpoint = result else {
            return XCTFail("expected .untrustedEndpoint when PID path unresolvable, got \(result)")
        }
    }

    // MARK: - C2: Path-prefix bypass prevention

    /// C2: path like /Users/x/Applications/Ollama.app/... must NOT be trusted.
    func testUserScopedApplicationsPathIsRejected() async throws {
        let data = try XCTUnwrap(#"{"version":"0.1.32"}"#.data(using: .utf8))
        let session = makeSession(responding: data)
        let lsof = ollamaLsof(pid: 7)
        // Simulates a binary installed under a user's ~/Applications (bypass attempt)
        let probe = OllamaTrustProbe(
            session: session,
            lsofRunner: { lsof },
            binaryPathResolver: { _ in "/Users/attacker/Applications/Ollama.app/Contents/MacOS/ollama" }
        )
        let result = await probe.probe()
        guard case .untrustedEndpoint = result else {
            return XCTFail("expected .untrustedEndpoint for user-scoped Applications path, got \(result)")
        }
    }

    /// C2: /Applications/Ollama.app/ at the root (correct) must still be trusted.
    func testRootApplicationsPathIsTrusted() async throws {
        let data = try XCTUnwrap(#"{"version":"0.1.32"}"#.data(using: .utf8))
        let session = makeSession(responding: data)
        let lsof = ollamaLsof(pid: 8)
        let probe = OllamaTrustProbe(
            session: session,
            lsofRunner: { lsof },
            binaryPathResolver: { _ in "/Applications/Ollama.app/Contents/MacOS/ollama" }
        )
        let result = await probe.probe()
        guard case .trusted = result else {
            return XCTFail("expected .trusted for /Applications/Ollama.app path, got \(result)")
        }
    }

    /// C2: /usr/local/bin/ollama must be trusted.
    func testUsrLocalBinaryIsTrusted() async throws {
        let data = try XCTUnwrap(#"{"version":"0.1.32"}"#.data(using: .utf8))
        let session = makeSession(responding: data)
        let lsof = ollamaLsof(pid: 9)
        let probe = OllamaTrustProbe(
            session: session,
            lsofRunner: { lsof },
            binaryPathResolver: { _ in "/usr/local/bin/ollama" }
        )
        let result = await probe.probe()
        guard case .trusted = result else {
            return XCTFail("expected .trusted for /usr/local/bin/ollama, got \(result)")
        }
    }
}

// MARK: - Mock URL Protocol

final class OllamaMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Data, URLResponse))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = OllamaMockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (data, response) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
