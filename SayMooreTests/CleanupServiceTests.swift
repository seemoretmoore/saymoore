import XCTest
@testable import SayMoore

final class CleanupServiceTests: XCTestCase {

    private struct StubPresets: PresetResolving {
        var vocab: [VocabEntry] = []
        func preset(for bundleID: String?) -> Preset {
            Preset(name: "stub", promptTemplate: "{{transcript}}")
        }
        func vocabulary() -> [VocabEntry] { vocab }
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

    // MARK: - Response validation (Slice 12 P0 fix)
    //
    // Whisper occasionally hands the cleanup LLM input that triggers placeholder
    // or meta-commentary responses ("N/A", "nothing to clean here"). Those must
    // throw .cleanupFailed so PipelineCoordinator falls back to pasting raw.

    private func expectCleanupFailed(_ response: String, raw: String, file: StaticString = #filePath, line: UInt = #line) async {
        let fake = FakeOllama()
        fake.nextResult = .success(response)
        let svc = CleanupService(client: fake, presets: StubPresets())
        do {
            _ = try await svc.clean(raw, bundleID: nil)
            XCTFail("expected cleanupFailed for response \"\(response)\"", file: file, line: line)
        } catch let e as SayMooreError {
            switch e {
            case .cleanupFailed: break
            default: XCTFail("expected .cleanupFailed, got \(e)", file: file, line: line)
            }
        } catch {
            XCTFail("wrong error: \(error)", file: file, line: line)
        }
    }

    func testRejectsNAResponse() async {
        await expectCleanupFailed("N/A", raw: "tell mom i'll call her after work")
    }

    func testRejectsNAResponseWithPunctuation() async {
        await expectCleanupFailed("N/A.", raw: "tell mom i'll call her after work")
    }

    func testRejectsMetaCommentaryResponse() async {
        await expectCleanupFailed("nothing to clean here", raw: "i had a really good time tonight thank you for everything")
    }

    func testRejectsEmptyResponse() async {
        await expectCleanupFailed("   \n  ", raw: "hi there everyone")
    }

    func testRejectsLengthCollapse() async {
        // Input 100+ chars, output 5 chars → collapse.
        let raw = String(repeating: "this is a long dictation that the cleanup should not collapse. ", count: 2)
        await expectCleanupFailed("ok.", raw: raw)
    }

    func testAcceptsShortValidResponse() async throws {
        // Short raw + short clean must NOT trip the length-collapse floor.
        let fake = FakeOllama()
        fake.nextResult = .success("Yes.")
        let svc = CleanupService(client: fake, presets: StubPresets())
        let out = try await svc.clean("Yes", bundleID: nil)
        XCTAssertEqual(out, "Yes.")
    }

    func testAcceptsLegitimateShortening() async throws {
        // Raw 30 chars, cleaned 25 chars — within the 20% floor.
        let fake = FakeOllama()
        fake.nextResult = .success("Confirm the package was delivered?")
        let svc = CleanupService(client: fake, presets: StubPresets())
        let out = try await svc.clean("Can you confirm that the package was delivered?", bundleID: nil)
        XCTAssertEqual(out, "Confirm the package was delivered?")
    }
}
