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

    // MARK: - Network failure → probeFailed

    func testProbeFailedOnTimeout() async throws {
        let session = makeSession(error: URLError(.timedOut))
        let lsof = ollamaLsof()
        let probe = OllamaTrustProbe(
            session: session,
            lsofRunner: { lsof },
            binaryPathResolver: { _ in "/Applications/Ollama.app/Contents/MacOS/ollama" }
        )
        let result = await probe.probe()
        guard case .probeFailed = result else {
            return XCTFail("expected .probeFailed, got \(result)")
        }
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
