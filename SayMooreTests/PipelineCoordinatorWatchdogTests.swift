import XCTest
@testable import SayMoore

@MainActor
final class PipelineCoordinatorWatchdogTests: XCTestCase {

    private final class FakeRecorder: AudioRecording {
        var isRecording: Bool = false
        var vadService: VADService?
        var samples: [Float] = Array(repeating: 0.5, count: 16_000)
        func start() throws { isRecording = true }
        func stop() throws -> [Float] { isRecording = false; return samples }
        func cancel() { isRecording = false }
    }

    private final class FakePasteboard: PasteboardAdapter, @unchecked Sendable {
        var changeCount: Int = 0
        var current: String? = nil
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
        init(bundleID: String?) { self.bundleID = bundleID }
    }
    private struct StubPresets: PresetResolving {
        func preset(for bundleID: String?) -> Preset {
            Preset(name: "stub", promptTemplate: "{{transcript}}")
        }
        func vocabulary() -> [VocabEntry] { [] }
        func snippets() -> [String: String] { [:] }
    }

    /// Transcription service that hangs forever (until cancelled), simulating a
    /// stuck pipeline so the watchdog must fire.
    private final class StuckTranscription: TranscriptionService, @unchecked Sendable {
        func transcribe(samples: [Float], sampleRate: Int, initialPrompt: String?) async throws -> Transcript {
            try await Task.sleep(nanoseconds: 10_000_000_000) // 10s
            return Transcript(text: "never", averageNoSpeechProb: 0)
        }
    }

    /// The watchdog must NOT fire during recording — recording length is
    /// already capped by the length-cap timers (60/80/90s). If the watchdog
    /// armed during recording, a slow-but-not-stuck user (≥30s of natural
    /// speech) would be cut off and, worse, the recorder would be left in
    /// a half-stopped state where the next start() short-circuits on the
    /// stale isRecording flag and fuses sessions on the next stop().
    func test_watchdogDoesNotFireDuringRecording() async throws {
        let state = AppState()
        let recorder = FakeRecorder()
        let paste = PasteService(
            pasteboard: FakePasteboard(),
            keyboard: FakeKeyboard(),
            frontmost: FakeFrontmost(bundleID: "x"),
            restoreDelay: .zero
        )
        var fallback: SayMooreError?
        let coord = PipelineCoordinator(
            appState: state,
            recorder: recorder,
            transcription: StuckTranscription(),
            paste: paste,
            presets: StubPresets(),
            cleanup: nil,
            recordingsDir: nil,
            persistRawWAV: false,
            vadService: nil,
            lengthCapCaution: 1000,
            lengthCapWarning: 1000,
            lengthCapHardStop: 1000,
            watchdogTimeout: 0.15,
            onFallback: { fallback = $0 }
        )
        coord.toggle(bundleID: "x")   // start recording, do NOT stop
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(state.state, .recording, "watchdog must not fire during recording")
        XCTAssertTrue(recorder.isRecording)
        XCTAssertNil(fallback)
    }

    func test_watchdogFires_whenPipelineStuckInTranscribing() async throws {
        let state = AppState()
        let recorder = FakeRecorder()
        let stuck = StuckTranscription()
        let paste = PasteService(
            pasteboard: FakePasteboard(),
            keyboard: FakeKeyboard(),
            frontmost: FakeFrontmost(bundleID: "x"),
            restoreDelay: .zero
        )
        let presets = StubPresets()
        var fallback: SayMooreError?
        let coord = PipelineCoordinator(
            appState: state,
            recorder: recorder,
            transcription: stuck,
            paste: paste,
            presets: presets,
            cleanup: nil,
            recordingsDir: nil,
            persistRawWAV: false,
            vadService: nil,
            lengthCapCaution: 1000,
            lengthCapWarning: 1000,
            lengthCapHardStop: 1000,
            watchdogTimeout: 0.2,
            onFallback: { fallback = $0 }
        )
        coord.toggle(bundleID: "x")   // start recording
        coord.toggle(bundleID: "x")   // stop → transcribing → stuck
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(fallback, .watchdogTimeout)
        XCTAssertEqual(state.state, .idle)
    }
}
