import XCTest
@testable import SayMoore

/// Verifies that `PipelineCoordinator` reads `presets.vocabulary()` at
/// transcribe-time and forwards it to `TranscriptionService.transcribe`.
/// (The formatter `PresetStore.vocabularyPromptString(_:)` is unit-tested in
/// `PresetStoreTests`.)
@MainActor
final class TranscriptionVocabBiasTests: XCTestCase {

    private final class FakeRecorder: AudioRecording {
        var isRecording = false
        var samples: [Float] = Array(repeating: 0.5, count: 16_000)
        func start() throws { isRecording = true }
        func stop() throws -> [Float] { isRecording = false; return samples }
        func cancel() { isRecording = false }
    }
    private final class FakePasteboard: PasteboardAdapter, @unchecked Sendable {
        var changeCount = 0
        var current: String? = "previous"
        func savedString() -> String? { current }
        func clearContents() { current = nil }
        func setString(_ s: String) { current = s; changeCount += 1 }
    }
    private final class FakeKeyboard: KeyboardAdapter, @unchecked Sendable {
        func postCmdV() {}
    }
    private final class FakeFrontmost: FrontmostAdapter, @unchecked Sendable {
        var bundleID: String?
    }
    private struct StubPresets: PresetResolving {
        let vocab: [String]
        func preset(for bundleID: String?) -> Preset {
            Preset(name: "stub", promptTemplate: "{{transcript}}")
        }
        func vocabulary() -> [String] { vocab }
    }

    private func runOnce(vocabulary: [String]) async throws -> [String] {
        let rec = FakeRecorder()
        let trans = FakeTranscriptionService()
        trans.nextResult = .success(Transcript(text: "hello world test", averageNoSpeechProb: 0))
        let paste = PasteService(
            pasteboard: FakePasteboard(), keyboard: FakeKeyboard(),
            frontmost: FakeFrontmost(), restoreDelay: .zero
        )
        let coord = PipelineCoordinator(
            appState: AppState(),
            recorder: rec,
            transcription: trans,
            paste: paste,
            presets: StubPresets(vocab: vocabulary)
        )
        coord.toggle(bundleID: "com.apple.TextEdit")
        coord.toggle(bundleID: nil)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(trans.calls, 1)
        return trans.lastVocabulary
    }

    func testEmptyVocabularyForwardsAsEmptyArray() async throws {
        let seen = try await runOnce(vocabulary: [])
        XCTAssertEqual(seen, [])
    }

    func testPopulatedVocabularyForwardsVerbatim() async throws {
        let seen = try await runOnce(vocabulary: ["FSEventStream", "Qwen", "AVAudioEngine"])
        XCTAssertEqual(seen, ["FSEventStream", "Qwen", "AVAudioEngine"])
    }
}
