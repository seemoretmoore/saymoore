import XCTest
@testable import SayMoore

/// Asserts that `PresetStore.cleanupGlossaryLine` is injected into the
/// cleanup-LLM prompt above the `<transcript>` fence when vocabulary is
/// non-empty, and omitted entirely when empty.
///
/// This is the post-pivot replacement for `TranscriptionVocabBiasTests`
/// (which asserted whisper-side vocab forwarding — now obsolete).
final class CleanupServiceVocabularyTests: XCTestCase {

    private struct StubPresets: PresetResolving {
        var vocab: [String] = []
        func preset(for bundleID: String?) -> Preset {
            Preset(name: "stub", promptTemplate: "{{transcript}}")
        }
        func vocabulary() -> [String] { vocab }
    }

    private final class FakeOllama: OllamaClient, @unchecked Sendable {
        var nextResult: Result<String, Error> = .success("ok")
        private(set) var lastPrompt: String?
        func generate(model: String, prompt: String, timeout: TimeInterval) async throws -> String {
            lastPrompt = prompt
            return try nextResult.get()
        }
        func tags() async throws -> [String] { [] }
    }

    // MARK: - buildPrompt unit tests

    func testBuildPromptOmitsGlossaryWhenVocabEmpty() {
        let out = CleanupService.buildPrompt(template: "{{transcript}}", transcript: "hello", vocabulary: [])
        XCTAssertFalse(out.contains("Known technical terms"))
    }

    func testBuildPromptInjectsGlossaryWhenVocabNonEmpty() {
        let out = CleanupService.buildPrompt(
            template: "{{transcript}}",
            transcript: "hello",
            vocabulary: ["FSEventStream", "AVAudioEngine"]
        )
        XCTAssertTrue(
            out.contains("Known technical terms (preserve exact spelling, including camelCase): FSEventStream, AVAudioEngine."),
            "glossary line must appear with expected wording"
        )
    }

    func testBuildPromptPlacesGlossaryAboveTranscriptFence() {
        let out = CleanupService.buildPrompt(
            template: "{{transcript}}",
            transcript: "hello",
            vocabulary: ["FSEventStream"]
        )
        let glossaryIdx = out.range(of: "Known technical terms")
        let fenceIdx = out.range(of: "<transcript>")
        XCTAssertNotNil(glossaryIdx)
        XCTAssertNotNil(fenceIdx)
        if let g = glossaryIdx, let f = fenceIdx {
            XCTAssertLessThan(g.lowerBound, f.lowerBound, "glossary must precede the transcript fence")
        }
    }

    // MARK: - end-to-end via clean()

    func testCleanForwardsPresetsVocabularyIntoPrompt() async throws {
        let fake = FakeOllama()
        let presets = StubPresets(vocab: ["FSEventStream", "Qwen", "AVAudioEngine"])
        let svc = CleanupService(client: fake, presets: presets)
        _ = try await svc.clean("hi there", bundleID: nil)
        let prompt = try XCTUnwrap(fake.lastPrompt)
        XCTAssertTrue(prompt.contains("FSEventStream"))
        XCTAssertTrue(prompt.contains("Qwen"))
        XCTAssertTrue(prompt.contains("AVAudioEngine"))
        XCTAssertTrue(prompt.contains("Known technical terms"))
    }

    func testCleanOmitsGlossaryWhenPresetsVocabularyIsEmpty() async throws {
        let fake = FakeOllama()
        let svc = CleanupService(client: fake, presets: StubPresets(vocab: []))
        _ = try await svc.clean("hi there", bundleID: nil)
        let prompt = try XCTUnwrap(fake.lastPrompt)
        XCTAssertFalse(prompt.contains("Known technical terms"))
    }
}
