import XCTest
@testable import SayMoore

final class OllamaServiceTests: XCTestCase {

    override class func setUp() {
        URLProtocol.registerClass(StubURLProtocol.self)
    }
    override class func tearDown() {
        URLProtocol.unregisterClass(StubURLProtocol.self)
    }
    override func tearDown() {
        StubURLProtocol.stub = nil
        super.tearDown()
    }

    private func makeService() -> OllamaService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        return OllamaService(baseURL: URL(string: "http://localhost:11434")!, session: session)
    }

    func testGenerateHappyPathReturnsResponseField() async throws {
        StubURLProtocol.stub = .init(
            handler: { _ in
                let body = #"{"response":"hello cleaned"}"#.data(using: .utf8)!
                let resp = HTTPURLResponse(url: URL(string: "http://localhost:11434/api/generate")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, body, nil)
            }
        )
        let svc = makeService()
        let out = try await svc.generate(model: "m", prompt: "p", timeout: 5)
        XCTAssertEqual(out, "hello cleaned")
    }

    func test404MapsToOllamaModelNotPulled() async {
        StubURLProtocol.stub = .init(
            handler: { _ in
                let resp = HTTPURLResponse(url: URL(string: "http://localhost:11434/api/generate")!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (resp, Data(), nil)
            }
        )
        let svc = makeService()
        do {
            _ = try await svc.generate(model: "m", prompt: "p", timeout: 5)
            XCTFail("expected throw")
        } catch let err as SayMooreError {
            XCTAssertEqual(err, .ollamaModelNotPulled)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testConnectionRefusedMapsToOllamaUnreachable() async {
        StubURLProtocol.stub = .init(
            handler: { _ in
                let err = URLError(.cannotConnectToHost)
                return (nil, nil, err)
            }
        )
        let svc = makeService()
        do {
            _ = try await svc.generate(model: "m", prompt: "p", timeout: 5)
            XCTFail("expected throw")
        } catch let err as SayMooreError {
            XCTAssertEqual(err, .ollamaUnreachable)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testTimeoutMapsToCleanupTimedOut() async {
        StubURLProtocol.stub = .init(
            handler: { _ in
                return (nil, nil, URLError(.timedOut))
            }
        )
        let svc = makeService()
        do {
            _ = try await svc.generate(model: "m", prompt: "p", timeout: 5)
            XCTFail("expected throw")
        } catch let err as SayMooreError {
            XCTAssertEqual(err, .cleanupTimedOut)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // E1: wall-clock timeout fires before slow response
    func testGenerateWallClockTimeoutThrowsCleanupTimedOut() async {
        StubURLProtocol.stub = .init(
            handler: { _ in
                Thread.sleep(forTimeInterval: 2.0)
                let body = #"{"response":"late"}"#.data(using: .utf8)!
                let resp = HTTPURLResponse(url: URL(string: "http://localhost:11434/api/generate")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, body, nil)
            }
        )
        let svc = makeService()
        let start = Date()
        do {
            _ = try await svc.generate(model: "m", prompt: "p", timeout: 0.5)
            XCTFail("expected throw")
        } catch let err as SayMooreError {
            XCTAssertEqual(err, .cleanupTimedOut)
            XCTAssertLessThan(Date().timeIntervalSince(start), 1.2, "should time out well under 2s")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // E2: tags() hard 3s wall-clock timeout throws ollamaUnreachable
    func testTagsWallClockTimeoutThrowsOllamaUnreachable() async {
        StubURLProtocol.stub = .init(
            handler: { _ in
                Thread.sleep(forTimeInterval: 5.0)
                let body = #"{"models":[]}"#.data(using: .utf8)!
                let resp = HTTPURLResponse(url: URL(string: "http://localhost:11434/api/tags")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, body, nil)
            }
        )
        let svc = makeService()
        let start = Date()
        do {
            _ = try await svc.tags()
            XCTFail("expected throw")
        } catch let err as SayMooreError {
            XCTAssertEqual(err, .ollamaUnreachable)
            XCTAssertLessThan(Date().timeIntervalSince(start), 3.5, "should time out well under 5s")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testTagsHappyPathReturnsModelNames() async throws {
        StubURLProtocol.stub = .init(
            handler: { _ in
                let body = #"{"models":[{"name":"qwen2.5:7b-instruct"},{"name":"llama3:8b"}]}"#.data(using: .utf8)!
                let resp = HTTPURLResponse(url: URL(string: "http://localhost:11434/api/tags")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, body, nil)
            }
        )
        let svc = makeService()
        let names = try await svc.tags()
        XCTAssertEqual(names, ["qwen2.5:7b-instruct", "llama3:8b"])
    }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: @unchecked Sendable {
        let handler: (URLRequest) -> (HTTPURLResponse?, Data?, Error?)
    }
    nonisolated(unsafe) static var stub: Stub?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let stub = Self.stub else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let (resp, data, err) = stub.handler(request)
        if let err {
            client?.urlProtocol(self, didFailWithError: err)
            return
        }
        if let resp {
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        }
        if let data {
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
