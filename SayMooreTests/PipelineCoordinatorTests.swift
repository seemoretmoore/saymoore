import XCTest
@testable import SayMoore

@MainActor
final class PipelineCoordinatorTests: XCTestCase {

    private final class FakeRecorder: AudioRecording {
        var isRecording: Bool = false
        var vadService: VADService?
        var samples: [Float] = Array(repeating: 0.5, count: 16_000)
        var startError: Error?
        var stopError: Error?
        private(set) var startCalls = 0
        private(set) var stopCalls = 0
        private(set) var cancelCalls = 0

        func start() throws {
            startCalls += 1
            if let e = startError { throw e }
            isRecording = true
        }
        func stop() throws -> [Float] {
            stopCalls += 1
            if let e = stopError { throw e }
            isRecording = false
            return samples
        }
        func cancel() {
            cancelCalls += 1
            isRecording = false
        }
    }

    private final class FakePasteboard: PasteboardAdapter, @unchecked Sendable {
        var changeCount: Int = 0
        var current: String? = "previous"
        func savedString() -> String? { current }
        func clearContents() { current = nil }
        func setString(_ s: String) { current = s; changeCount += 1 }
    }
    private final class FakeKeyboard: KeyboardAdapter, @unchecked Sendable {
        var pastes = 0
        func postCmdV() { pastes += 1 }
    }
    private final class FakeFrontmost: FrontmostAdapter, @unchecked Sendable {
        var bundleID: String?
    }
    private struct StubPresets: PresetResolving {
        func preset(for bundleID: String?) -> Preset {
            Preset(name: "stub", promptTemplate: "{{transcript}}")
        }
        func vocabulary() -> [VocabEntry] { [] }
    }
    private let stubPresets = StubPresets()

    private func makeServices(
        transcript: Transcript = Transcript(text: "hello", averageNoSpeechProb: 0)
    ) -> (FakeRecorder, FakeTranscriptionService, FakePasteboard, FakeKeyboard, FakeFrontmost, PasteService) {
        let rec = FakeRecorder()
        let trans = FakeTranscriptionService()
        trans.nextResult = .success(transcript)
        let pb = FakePasteboard()
        let kb = FakeKeyboard()
        let fm = FakeFrontmost()
        let paste = PasteService(
            pasteboard: pb, keyboard: kb, frontmost: fm,
            restoreDelay: .zero
        )
        return (rec, trans, pb, kb, fm, paste)
    }

    // MARK: - Happy path

    func testHappyPathTranscribesPastesAndReturnsToIdle() async throws {
        let (rec, trans, _, kb, fm, paste) = makeServices()
        fm.bundleID = "com.apple.TextEdit"
        let state = AppState()
        let coord = PipelineCoordinator(
            appState: state, recorder: rec,
            transcription: trans, paste: paste, presets: stubPresets
        )

        coord.toggle(bundleID: "com.apple.TextEdit")
        XCTAssertEqual(state.state, .recording)
        XCTAssertEqual(rec.startCalls, 1)

        coord.toggle(bundleID: nil) // second tap closes recording
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(state.state, .idle)
        XCTAssertEqual(trans.calls, 1)
        XCTAssertEqual(kb.pastes, 1)
    }

    // MARK: - Garbage transcript

    func testGarbageTranscriptTransitionsToErrorThenIdleAndDoesNotPaste() async throws {
        let (rec, trans, _, kb, fm, paste) = makeServices(
            transcript: Transcript(text: "...", averageNoSpeechProb: 0.95)
        )
        fm.bundleID = "com.apple.TextEdit"
        let state = AppState()
        var fallbackErrors: [SayMooreError] = []
        let coord = PipelineCoordinator(
            appState: state, recorder: rec,
            transcription: trans, paste: paste, presets: stubPresets,
            onFallback: { fallbackErrors.append($0) }
        )

        coord.toggle(bundleID: "com.apple.TextEdit")
        coord.toggle(bundleID: nil)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(state.state, .idle)
        XCTAssertEqual(kb.pastes, 0)
        XCTAssertEqual(fallbackErrors, [.transcriptionGarbage],
                       "garbage path must surface a notification via onFallback")
    }

    // MARK: - Empty transcript

    func testEmptyTranscriptReturnsToIdleWithoutPasting() async throws {
        let (rec, trans, _, kb, fm, paste) = makeServices(
            transcript: Transcript(text: "", averageNoSpeechProb: 0.05)
        )
        fm.bundleID = "com.apple.TextEdit"
        let state = AppState()
        let coord = PipelineCoordinator(
            appState: state, recorder: rec,
            transcription: trans, paste: paste, presets: stubPresets
        )
        coord.toggle(bundleID: "com.apple.TextEdit")
        coord.toggle(bundleID: nil)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(state.state, .idle)
        XCTAssertEqual(kb.pastes, 0)
    }

    // MARK: - Transcription error

    func testTranscriptionFailureLandsInIdleViaErrorState() async throws {
        let (rec, trans, _, _, fm, paste) = makeServices()
        trans.nextResult = .failure(SayMooreError.transcriptionFailed(underlying: NSError(domain: "x", code: 1)))
        fm.bundleID = "com.apple.TextEdit"
        let state = AppState()
        let coord = PipelineCoordinator(
            appState: state, recorder: rec,
            transcription: trans, paste: paste, presets: stubPresets
        )
        coord.toggle(bundleID: "com.apple.TextEdit")
        coord.toggle(bundleID: nil)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(state.state, .idle)
    }

    // MARK: - A1: Paste focus changed restores clipboard (no transcript leak)

    func testPasteFocusChangedRestoresClipboard() async throws {
        let (rec, trans, pb, kb, fm, paste) = makeServices(
            transcript: Transcript(text: "hello", averageNoSpeechProb: 0)
        )
        // captured at recording start, but frontmost moves before paste-time check
        fm.bundleID = "com.tinyspeck.slackmacgap"
        let state = AppState()
        let coord = PipelineCoordinator(
            appState: state, recorder: rec,
            transcription: trans, paste: paste, presets: stubPresets
        )
        coord.toggle(bundleID: "com.apple.TextEdit")
        coord.toggle(bundleID: nil)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(state.state, .idle)
        XCTAssertEqual(kb.pastes, 0)
        XCTAssertEqual(pb.current, "previous", "A1: clipboard restored to prior contents, not leaking transcript")
    }

    // MARK: - Cancel via Esc

    func testCancelDuringRecordingDiscardsAudioAndReturnsToIdle() async throws {
        let (rec, trans, _, kb, fm, paste) = makeServices()
        fm.bundleID = "com.apple.TextEdit"
        let state = AppState()
        let coord = PipelineCoordinator(
            appState: state, recorder: rec,
            transcription: trans, paste: paste, presets: stubPresets
        )
        coord.toggle(bundleID: "com.apple.TextEdit")
        XCTAssertEqual(state.state, .recording)

        coord.cancel()
        XCTAssertEqual(state.state, .idle)
        XCTAssertEqual(rec.cancelCalls, 1)
        XCTAssertEqual(trans.calls, 0)
        XCTAssertEqual(kb.pastes, 0)
    }

    // MARK: - Re-press during processing

    func testTogglesIgnoredDuringTranscribing() async throws {
        let (rec, trans, _, kb, fm, paste) = makeServices()
        // Make transcription block until we resolve it.
        let blocking = BlockingTranscriptionService()
        fm.bundleID = "com.apple.TextEdit"
        let state = AppState()
        let coord = PipelineCoordinator(
            appState: state, recorder: rec,
            transcription: blocking, paste: paste, presets: stubPresets
        )
        coord.toggle(bundleID: "com.apple.TextEdit")
        coord.toggle(bundleID: nil) // begin processing
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(state.state, .transcribing)

        // Extra toggle while transcribing should be ignored.
        coord.toggle(bundleID: "com.apple.TextEdit")
        XCTAssertEqual(state.state, .transcribing)

        blocking.resume(.success(Transcript(text: "hello", averageNoSpeechProb: 0)))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(state.state, .idle)
        XCTAssertEqual(kb.pastes, 1)
        _ = trans // silence unused
    }

    // MARK: - Slice 6: busy-hotkey hook fires when toggle ignored

    func testBusyHotkeyFiresWhenTogglePressedDuringTranscribing() async throws {
        let (rec, _, _, _, fm, paste) = makeServices()
        let blocking = BlockingTranscriptionService()
        fm.bundleID = "com.apple.TextEdit"
        let state = AppState()
        let coord = PipelineCoordinator(
            appState: state, recorder: rec,
            transcription: blocking, paste: paste, presets: stubPresets
        )
        var busyCount = 0
        coord.onBusyHotkey = { busyCount += 1 }

        coord.toggle(bundleID: "com.apple.TextEdit") // .idle → .recording
        coord.toggle(bundleID: nil)                  // .recording → kicks pipeline
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(state.state, .transcribing)
        XCTAssertEqual(busyCount, 0, "no busy fires for the legitimate start/stop pair")

        // Toggle during transcribing — pipeline in flight, processingTask non-nil.
        coord.toggle(bundleID: nil)
        XCTAssertEqual(busyCount, 1, "busy must fire when toggle hits the processingTask-in-flight guard")

        blocking.resume(.success(Transcript(text: "hello", averageNoSpeechProb: 0)))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(state.state, .idle)
    }

    // MARK: - C1: Triple-tap deduplication

    func testTripleTapOnlyRunsOnePipeline() async throws {
        let (rec, _, _, kb, fm, paste) = makeServices()
        let blocking = BlockingTranscriptionService()
        fm.bundleID = "com.apple.TextEdit"
        let state = AppState()
        let coord = PipelineCoordinator(
            appState: state, recorder: rec,
            transcription: blocking, paste: paste, presets: stubPresets
        )
        coord.toggle(bundleID: "com.apple.TextEdit") // .idle → .recording
        coord.toggle(bundleID: nil)                  // .recording → kicks off pipeline
        coord.toggle(bundleID: nil)                  // should be ignored — pipeline in flight
        coord.toggle(bundleID: nil)                  // should be ignored — pipeline in flight

        XCTAssertEqual(rec.stopCalls, 1, "stop must be called exactly once despite triple-tap")

        blocking.resume(.success(Transcript(text: "hello", averageNoSpeechProb: 0)))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(state.state, .idle)
        XCTAssertEqual(kb.pastes, 1)
    }

    // MARK: - C1: Synchronous state transition before Task continuation

    func testStateTranscribingBeforeTaskContinuationRuns() async throws {
        let (rec, _, _, _, fm, paste) = makeServices()
        let blocking = BlockingTranscriptionService()
        fm.bundleID = "com.apple.TextEdit"
        let state = AppState()
        let coord = PipelineCoordinator(
            appState: state, recorder: rec,
            transcription: blocking, paste: paste, presets: stubPresets
        )
        coord.toggle(bundleID: "com.apple.TextEdit")
        XCTAssertEqual(state.state, .recording)

        coord.toggle(bundleID: nil)
        // State must be .transcribing synchronously — before any await resumes.
        XCTAssertEqual(state.state, .transcribing, "state should be .transcribing synchronously after stop toggle")
        XCTAssertEqual(rec.stopCalls, 1, "stop must have been called synchronously")

        blocking.resume(.success(Transcript(text: "hello", averageNoSpeechProb: 0)))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(state.state, .idle)
    }

    // MARK: - C1: blocked flag wiring

    /// C1: coordinator created with blocked=true refuses to start recording.
    func testBlockedCoordinatorRefusesToRecord() async throws {
        let (rec, _, _, _, _, paste) = makeServices()
        let state = AppState()
        var fallbackErrors: [SayMooreError] = []
        let coord = PipelineCoordinator(
            appState: state, recorder: rec,
            transcription: FakeTranscriptionService(), paste: paste, presets: stubPresets,
            onFallback: { fallbackErrors.append($0) }
        )
        coord.blocked = true
        coord.toggle(bundleID: nil)
        XCTAssertEqual(state.state, .idle, "blocked coordinator must not start recording")
        XCTAssertEqual(rec.startCalls, 0)
        XCTAssertEqual(fallbackErrors.count, 1)
        if case .ollamaEndpointUntrusted = fallbackErrors.first { } else {
            XCTFail("expected .ollamaEndpointUntrusted fallback, got \(String(describing: fallbackErrors.first))")
        }
    }

    /// C1: coordinator created with blocked=false starts recording normally.
    func testUnblockedCoordinatorStartsRecording() async throws {
        let (rec, _, _, _, fm, paste) = makeServices()
        fm.bundleID = "com.apple.TextEdit"
        let state = AppState()
        let coord = PipelineCoordinator(
            appState: state, recorder: rec,
            transcription: FakeTranscriptionService(), paste: paste, presets: stubPresets
        )
        coord.blocked = false
        coord.toggle(bundleID: "com.apple.TextEdit")
        XCTAssertEqual(state.state, .recording)
        XCTAssertEqual(rec.startCalls, 1)
        coord.cancel()
    }

    // MARK: - M3: Mid-pipeline blocked abort

    /// M3: if blocked becomes true while transcription is in flight,
    /// processSamples must abort before cleanup and return to idle.
    func testMidPipelineBlockAbortBeforeCleanup() async throws {
        let (rec, _, _, kb, fm, paste) = makeServices()
        fm.bundleID = "com.apple.TextEdit"
        let state = AppState()
        let blocking = BlockingTranscriptionService()
        var fallbackErrors: [SayMooreError] = []
        let coord = PipelineCoordinator(
            appState: state, recorder: rec,
            transcription: blocking, paste: paste, presets: stubPresets,
            onFallback: { fallbackErrors.append($0) }
        )
        coord.toggle(bundleID: "com.apple.TextEdit") // start recording
        coord.toggle(bundleID: nil)                  // stop → kicks off pipeline
        // Transcription is now in flight. Set blocked before resuming it.
        coord.blocked = true
        blocking.resume(.success(Transcript(text: "hello world test", averageNoSpeechProb: 0)))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(state.state, .idle, "should return to idle after blocked abort")
        XCTAssertEqual(kb.pastes, 0, "paste must not happen when blocked mid-pipeline")
        XCTAssertTrue(
            fallbackErrors.contains(where: { if case .ollamaEndpointUntrusted = $0 { return true } else { return false } }),
            "should emit .ollamaEndpointUntrusted error"
        )
    }

    // MARK: - C1: processingTask nil after pipeline completes

    func testProcessingTaskClearedAfterPipelineCompletes() async throws {
        let (rec, trans, _, _, fm, paste) = makeServices()
        fm.bundleID = "com.apple.TextEdit"
        let state = AppState()
        let coord = PipelineCoordinator(
            appState: state, recorder: rec,
            transcription: trans, paste: paste, presets: stubPresets
        )
        coord.toggle(bundleID: "com.apple.TextEdit")
        coord.toggle(bundleID: nil)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(state.state, .idle)
        // Second full recording cycle must succeed (processingTask was cleared).
        coord.toggle(bundleID: "com.apple.TextEdit")
        XCTAssertEqual(state.state, .recording)
        coord.toggle(bundleID: nil)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(state.state, .idle)
        XCTAssertEqual(rec.stopCalls, 2, "two full cycles = two stop calls")
    }

    // MARK: - Slice 5: length cap timers + VAD auto-stop

    func testLengthCapWarningFiresWhileRecording() async throws {
        let (rec, trans, _, _, fm, paste) = makeServices()
        fm.bundleID = "com.apple.TextEdit"
        let state = AppState()
        let fallbacks = FallbackRecorder()
        let coord = PipelineCoordinator(
            appState: state, recorder: rec,
            transcription: trans, paste: paste, presets: stubPresets,
            lengthCapWarning: 0.05, lengthCapHardStop: 5.0,
            onFallback: { fallbacks.record($0) }
        )

        coord.toggle(bundleID: "com.apple.TextEdit")
        XCTAssertEqual(state.state, .recording)

        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(fallbacks.contains(.recordingLengthWarning),
                      "warning should fire after lengthCapWarning elapsed; got \(fallbacks.snapshot())")
        // Hard stop hasn't elapsed yet — still recording.
        XCTAssertEqual(state.state, .recording)

        // Clean shutdown via normal toggle.
        coord.toggle(bundleID: nil)
        try await Task.sleep(for: .milliseconds(80))
    }

    func testLengthCapHardStopForcesStop() async throws {
        let (rec, trans, _, _, fm, paste) = makeServices()
        fm.bundleID = "com.apple.TextEdit"
        let state = AppState()
        let fallbacks = FallbackRecorder()
        let coord = PipelineCoordinator(
            appState: state, recorder: rec,
            transcription: trans, paste: paste, presets: stubPresets,
            lengthCapWarning: 5.0, lengthCapHardStop: 0.05,
            onFallback: { fallbacks.record($0) }
        )

        coord.toggle(bundleID: "com.apple.TextEdit")
        XCTAssertEqual(state.state, .recording)

        try await Task.sleep(for: .milliseconds(200))
        // Hard stop should have fired: recorder.stop called, banner posted.
        XCTAssertEqual(rec.stopCalls, 1, "hard cap should auto-stop the recorder")
        XCTAssertTrue(fallbacks.contains(.recordingTooLong),
                      "hard stop should post recordingTooLong banner; got \(fallbacks.snapshot())")
        XCTAssertEqual(state.state, .idle, "pipeline should progress to idle after auto-stop")
    }

    func testManualStopCancelsLengthCapTimers() async throws {
        let (rec, trans, _, _, fm, paste) = makeServices()
        fm.bundleID = "com.apple.TextEdit"
        let state = AppState()
        let fallbacks = FallbackRecorder()
        let coord = PipelineCoordinator(
            appState: state, recorder: rec,
            transcription: trans, paste: paste, presets: stubPresets,
            lengthCapWarning: 0.30, lengthCapHardStop: 0.40,
            onFallback: { fallbacks.record($0) }
        )

        coord.toggle(bundleID: "com.apple.TextEdit")
        // Stop well before warning fires.
        try await Task.sleep(for: .milliseconds(20))
        coord.toggle(bundleID: nil)
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertFalse(fallbacks.contains(.recordingLengthWarning),
                       "manual stop must cancel the warning timer")
        XCTAssertFalse(fallbacks.contains(.recordingTooLong),
                       "manual stop must cancel the hard-stop timer")
        XCTAssertEqual(rec.stopCalls, 1, "single stop from the manual toggle, not from hard cap")
    }

    func testEscCancelCancelsLengthCapTimers() async throws {
        let (rec, trans, _, _, fm, paste) = makeServices()
        fm.bundleID = "com.apple.TextEdit"
        let state = AppState()
        let fallbacks = FallbackRecorder()
        let coord = PipelineCoordinator(
            appState: state, recorder: rec,
            transcription: trans, paste: paste, presets: stubPresets,
            lengthCapWarning: 0.30, lengthCapHardStop: 0.40,
            onFallback: { fallbacks.record($0) }
        )

        coord.toggle(bundleID: "com.apple.TextEdit")
        try await Task.sleep(for: .milliseconds(20))
        coord.cancel()
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertFalse(fallbacks.contains(.recordingLengthWarning))
        XCTAssertFalse(fallbacks.contains(.recordingTooLong))
        XCTAssertEqual(rec.cancelCalls, 1)
    }

    func testVADSilenceAutoStopsRecording() async throws {
        let (rec, trans, _, _, fm, paste) = makeServices()
        fm.bundleID = "com.apple.TextEdit"
        let state = AppState()

        // Build a VAD service with a Fake backend that classifies every frame
        // as silence and a tiny threshold so the observer fires quickly.
        let backend = FakeVADBackend(canned: [.silence])
        let vad = VADService(
            backend: backend,
            silenceThreshold: 5 * VADService.frameDuration
        )

        let coord = PipelineCoordinator(
            appState: state, recorder: rec,
            transcription: trans, paste: paste, presets: stubPresets,
            vadService: vad,
            lengthCapWarning: 10.0, lengthCapHardStop: 20.0
        )

        coord.toggle(bundleID: "com.apple.TextEdit")
        XCTAssertEqual(state.state, .recording)
        XCTAssertNotNil(rec.vadService, "VAD should be attached to recorder on init")

        // Manually feed enough silence frames to cross the threshold.
        vad.feed(Array(repeating: Float(0), count: 20 * VADService.frameSamples))
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(rec.stopCalls, 1, "VAD silence threshold should auto-stop the recorder")
        XCTAssertEqual(state.state, .idle, "pipeline should reach idle after VAD auto-stop")
    }

    // MARK: - Slice 6: length-cap colour pill phase

    private final class PhaseRecorder {
        private(set) var phases: [PipelineCoordinator.LengthCapPhase] = []
        func record(_ p: PipelineCoordinator.LengthCapPhase) { phases.append(p) }
    }

    func testLengthCapPhase_FiresNormalImmediatelyOnRecord() async throws {
        let (rec, trans, _, _, fm, paste) = makeServices()
        fm.bundleID = "com.apple.TextEdit"
        let state = AppState()
        let phases = PhaseRecorder()
        let coord = PipelineCoordinator(
            appState: state, recorder: rec,
            transcription: trans, paste: paste, presets: stubPresets,
            lengthCapCaution: 5.0, lengthCapWarning: 5.5, lengthCapHardStop: 6.0
        )
        coord.onLengthCapPhase = { phases.record($0) }

        coord.toggle(bundleID: "com.apple.TextEdit")
        XCTAssertEqual(state.state, .recording)
        XCTAssertTrue(phases.phases.contains(.normal),
                      "phase .normal must fire immediately on record start; got \(phases.phases)")

        coord.toggle(bundleID: nil)
        try await Task.sleep(for: .milliseconds(80))
    }

    func testLengthCapPhase_FiresCautionAtThreshold() async throws {
        let (rec, trans, _, _, fm, paste) = makeServices()
        fm.bundleID = "com.apple.TextEdit"
        let state = AppState()
        let phases = PhaseRecorder()
        let coord = PipelineCoordinator(
            appState: state, recorder: rec,
            transcription: trans, paste: paste, presets: stubPresets,
            lengthCapCaution: 0.05, lengthCapWarning: 5.0, lengthCapHardStop: 6.0
        )
        coord.onLengthCapPhase = { phases.record($0) }

        coord.toggle(bundleID: "com.apple.TextEdit")
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(phases.phases.contains(.caution),
                      "phase .caution must fire after lengthCapCaution; got \(phases.phases)")

        coord.toggle(bundleID: nil)
        try await Task.sleep(for: .milliseconds(80))
    }

    func testLengthCapPhase_FiresWarningAlongsideBanner() async throws {
        let (rec, trans, _, _, fm, paste) = makeServices()
        fm.bundleID = "com.apple.TextEdit"
        let state = AppState()
        let fallbacks = FallbackRecorder()
        let phases = PhaseRecorder()
        let coord = PipelineCoordinator(
            appState: state, recorder: rec,
            transcription: trans, paste: paste, presets: stubPresets,
            lengthCapCaution: 0.02, lengthCapWarning: 0.05, lengthCapHardStop: 5.0,
            onFallback: { fallbacks.record($0) }
        )
        coord.onLengthCapPhase = { phases.record($0) }

        coord.toggle(bundleID: "com.apple.TextEdit")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(phases.phases.contains(.warning),
                      "phase .warning must fire at lengthCapWarning; got \(phases.phases)")
        XCTAssertTrue(fallbacks.contains(.recordingLengthWarning),
                      "warning banner must still fire alongside .warning phase")

        coord.toggle(bundleID: nil)
        try await Task.sleep(for: .milliseconds(80))
    }

    func testLengthCapPhase_FiresIdleOnCancel() async throws {
        let (rec, trans, _, _, fm, paste) = makeServices()
        fm.bundleID = "com.apple.TextEdit"
        let state = AppState()
        let phases = PhaseRecorder()
        let coord = PipelineCoordinator(
            appState: state, recorder: rec,
            transcription: trans, paste: paste, presets: stubPresets,
            lengthCapCaution: 5.0, lengthCapWarning: 5.5, lengthCapHardStop: 6.0
        )
        coord.onLengthCapPhase = { phases.record($0) }

        coord.toggle(bundleID: "com.apple.TextEdit")
        coord.cancel()
        XCTAssertEqual(state.state, .idle)
        XCTAssertTrue(phases.phases.last == .idle,
                      "phase .idle must be the last fired after cancel; got \(phases.phases)")
    }
}

/// Records onFallback callbacks for assertions across timer tests.
@MainActor
private final class FallbackRecorder {
    private var calls: [SayMooreError] = []
    func record(_ e: SayMooreError) { calls.append(e) }
    func contains(_ e: SayMooreError) -> Bool { calls.contains(e) }
    func snapshot() -> [SayMooreError] { calls }
}

@MainActor
private final class BlockingTranscriptionService: TranscriptionService {
    private var continuation: CheckedContinuation<Transcript, Error>?
    private var pendingResult: Result<Transcript, Error>?

    nonisolated func transcribe(samples: [Float], sampleRate: Int) async throws -> Transcript {
        return try await withCheckedThrowingContinuation { cont in
            Task { @MainActor in
                if let r = self.pendingResult {
                    self.pendingResult = nil
                    cont.resume(with: r)
                } else {
                    self.continuation = cont
                }
            }
        }
    }
    func resume(_ result: Result<Transcript, Error>) {
        if let c = continuation {
            continuation = nil
            c.resume(with: result)
        } else {
            // resume() arrived before transcribe stored the continuation — buffer it.
            pendingResult = result
        }
    }
}
