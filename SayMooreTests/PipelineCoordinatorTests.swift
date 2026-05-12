import XCTest
@testable import SayMoore

@MainActor
final class PipelineCoordinatorTests: XCTestCase {

    private final class FakeRecorder: AudioRecording {
        var isRecording: Bool = false
        var samples: [Float] = Array(repeating: 0.5, count: 16_000)
        var startError: Error?
        var stopError: Error?
        private(set) var startCalls = 0
        private(set) var cancelCalls = 0

        func start() throws {
            startCalls += 1
            if let e = startError { throw e }
            isRecording = true
        }
        func stop() throws -> [Float] {
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
            transcription: trans, paste: paste
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
        let coord = PipelineCoordinator(
            appState: state, recorder: rec,
            transcription: trans, paste: paste
        )

        coord.toggle(bundleID: "com.apple.TextEdit")
        coord.toggle(bundleID: nil)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(state.state, .idle)
        XCTAssertEqual(kb.pastes, 0)
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
            transcription: trans, paste: paste
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
            transcription: trans, paste: paste
        )
        coord.toggle(bundleID: "com.apple.TextEdit")
        coord.toggle(bundleID: nil)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(state.state, .idle)
    }

    // MARK: - Paste focus changed leaves transcript on clipboard

    func testPasteFocusChangedTranscriptStaysOnClipboard() async throws {
        let (rec, trans, pb, kb, fm, paste) = makeServices(
            transcript: Transcript(text: "hello", averageNoSpeechProb: 0)
        )
        // captured at recording start, but frontmost moves before paste-time check
        fm.bundleID = "com.tinyspeck.slackmacgap"
        let state = AppState()
        let coord = PipelineCoordinator(
            appState: state, recorder: rec,
            transcription: trans, paste: paste
        )
        coord.toggle(bundleID: "com.apple.TextEdit")
        coord.toggle(bundleID: nil)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(state.state, .idle)
        XCTAssertEqual(kb.pastes, 0)
        XCTAssertEqual(pb.current, "hello", "transcript stays on clipboard for manual paste")
    }

    // MARK: - Cancel via Esc

    func testCancelDuringRecordingDiscardsAudioAndReturnsToIdle() async throws {
        let (rec, trans, _, kb, fm, paste) = makeServices()
        fm.bundleID = "com.apple.TextEdit"
        let state = AppState()
        let coord = PipelineCoordinator(
            appState: state, recorder: rec,
            transcription: trans, paste: paste
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
            transcription: blocking, paste: paste
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
}

@MainActor
private final class BlockingTranscriptionService: TranscriptionService {
    private var continuation: CheckedContinuation<Transcript, Error>?
    nonisolated func transcribe(samples: [Float], sampleRate: Int) async throws -> Transcript {
        return try await withCheckedThrowingContinuation { cont in
            Task { @MainActor in
                self.continuation = cont
            }
        }
    }
    func resume(_ result: Result<Transcript, Error>) {
        switch result {
        case .success(let t): continuation?.resume(returning: t)
        case .failure(let e): continuation?.resume(throwing: e)
        }
        continuation = nil
    }
}
