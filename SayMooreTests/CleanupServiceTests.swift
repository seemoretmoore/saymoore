import XCTest
@testable import SayMoore

final class CleanupServiceTests: XCTestCase {

    private struct StubPresets: PresetResolving {
        func preset(for bundleID: String?) -> Preset {
            Preset(name: "stub", promptTemplate: "{{transcript}}")
        }
    }

    private final class FakeOllama: OllamaClient, @unchecked Sendable {
        var nextResult: Result<String, Error> = .success("")
        private(set) var lastModel: String?
        private(set) var lastPrompt: String?
        private(set) var lastTimeout: TimeInterval?
        func generate(model: String, prompt: String, timeout: TimeInterval) async throws -> String {
            lastModel = model; lastPrompt = prompt; lastTimeout = timeout
            switch nextResult {
            case .success(let s): return s
            case .failure(let e): throw e
            }
        }
        func tags() async throws -> [String] { [] }
    }

    func testBuildPromptSubstitutesTranscriptToken() {
        let out = CleanupService.buildPrompt(template: "x{{transcript}}y", transcript: "HI")
        XCTAssertEqual(out, "x<transcript>\nHI\n</transcript>y")
    }

    func testCleanHappyPathPassesPromptAndModel() async throws {
        let fake = FakeOllama()
        fake.nextResult = .success("  cleaned text  ")
        let svc = CleanupService(client: fake, model: "qwen2.5:7b-instruct", presets: StubPresets())
        let out = try await svc.clean("uh hi there", bundleID: nil)
        XCTAssertEqual(out, "cleaned text")
        XCTAssertEqual(fake.lastModel, "qwen2.5:7b-instruct")
        XCTAssertTrue(fake.lastPrompt?.contains("uh hi there") ?? false)
        XCTAssertEqual(fake.lastTimeout, 10)
    }

    func testCleanPropagatesOllamaUnreachable() async {
        let fake = FakeOllama()
        fake.nextResult = .failure(SayMooreError.ollamaUnreachable)
        let svc = CleanupService(client: fake, presets: StubPresets())
        do {
            _ = try await svc.clean("hi there everyone", bundleID: nil)
            XCTFail("expected throw")
        } catch let e as SayMooreError {
            XCTAssertEqual(e, .ollamaUnreachable)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testCleanPropagatesTimeout() async {
        let fake = FakeOllama()
        fake.nextResult = .failure(SayMooreError.cleanupTimedOut)
        let svc = CleanupService(client: fake, presets: StubPresets())
        do {
            _ = try await svc.clean("hi there everyone", bundleID: nil)
            XCTFail("expected throw")
        } catch let e as SayMooreError {
            XCTAssertEqual(e, .cleanupTimedOut)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
