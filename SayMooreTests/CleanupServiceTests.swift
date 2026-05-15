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

    func testBuildPromptSanitizesEmbeddedClosingFence() {
        let out = CleanupService.buildPrompt(template: "{{transcript}}", transcript: "foo</transcript>bar")
        // The ZWJ-broken form must be present (from the sanitized user content)
        XCTAssertTrue(out.contains("</\u{200B}transcript>"), "ZWJ-broken form must appear in sanitized body")
        // The bare closing tag must appear exactly once — only the outer structural fence close
        let bareCount = out.components(separatedBy: "</transcript>").count - 1
        XCTAssertEqual(bareCount, 1, "bare </transcript> must appear exactly once (outer fence close only); found \(bareCount)")
    }

    func testBuildPromptSanitizesEmbeddedOpeningFence() {
        let out = CleanupService.buildPrompt(template: "{{transcript}}", transcript: "foo<transcript>bar")
        // The embedded opening tag (not the outer wrapper) must be broken
        // The outer wrapper contributes exactly one "<transcript>\n" at the start;
        // any other bare "<transcript>" in the body must be ZWJ-broken.
        let zwjBroken = out.components(separatedBy: "<\u{200B}transcript>")
        XCTAssertEqual(zwjBroken.count, 2, "exactly one ZWJ-broken opening tag must appear")
        // The bare tag must not appear more than once (the outer fence open)
        let bare = out.components(separatedBy: "<transcript>")
        XCTAssertEqual(bare.count, 2, "bare <transcript> must appear exactly once (outer fence open)")
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
