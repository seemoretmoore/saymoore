import XCTest
@testable import SayMoore

/// Regression: when streaming-partials mode is `.off` (the default for the
/// new no-op injected params), the coordinator MUST NOT subscribe to
/// `recorder.onSamples`. Subscribing is the gate that constructs the
/// `StreamingTranscriber` and feeds it audio; the off path must skip both.
@MainActor
final class PipelineCoordinatorStreamingOffTests: XCTestCase {

    private final class FakeRecorder: AudioRecording {
        var isRecording: Bool = false
        var vadService: VADService?
        var onSamples: (@Sendable ([Float]) -> Void)?
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
        func postCmdZ() {}
    }
    private final class FakeFrontmost: FrontmostAdapter, @unchecked Sendable {
        var bundleID: String?
    }
    private struct StubPresets: PresetResolving {
        func preset(for bundleID: String?) -> Preset {
            Preset(name: "stub", promptTemplate: "{{transcript}}")
        }
        func vocabulary() -> [VocabEntry] { [] }
        func snippets() -> [String: String] { [:] }
    }

    func testStreamingOffDoesNotSubscribeToRecorderOnSamples() {
        let rec = FakeRecorder()
        let trans = FakeTranscriptionService()
        let paste = PasteService(
            pasteboard: FakePasteboard(),
            keyboard: FakeKeyboard(),
            frontmost: FakeFrontmost(),
            restoreDelay: .zero
        )
        let coord = PipelineCoordinator(
            appState: AppState(),
            recorder: rec,
            transcription: trans,
            paste: paste,
            presets: StubPresets()
            // streamingModeProvider defaults to { .off } — no subscription.
        )

        coord.toggle(bundleID: "com.example.test")
        XCTAssertNil(rec.onSamples, "Off mode must not subscribe to recorder.onSamples")
        coord.cancel()
        XCTAssertNil(rec.onSamples, "Off mode cancel path must keep onSamples nil")
    }
}
