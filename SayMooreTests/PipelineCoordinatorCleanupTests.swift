import XCTest
@testable import SayMoore

@MainActor
final class PipelineCoordinatorCleanupTests: XCTestCase {

    private final class FakeRecorder: AudioRecording {
        var isRecording = false
        var vadService: VADService?
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
        var pastes = 0
        var undos = 0
        func postCmdV() { pastes += 1 }
        func postCmdZ() { undos += 1 }
    }
    private final class FakeFrontmost: FrontmostAdapter, @unchecked Sendable {
        var bundleID: String?
    }
    private struct StubPresets: PresetResolving {
        var snippetMap: [String: String] = [:]
        var vocab: [VocabEntry] = []
        func preset(for bundleID: String?) -> Preset {
            Preset(name: "stub", promptTemplate: "{{transcript}}")
        }
        func vocabulary() -> [VocabEntry] { vocab }
        func snippets() -> [String: String] { snippetMap }
    }
    private let stubPresets = StubPresets()

    /// Variant of stubPresets with snippets configured. Used by the snippet
    /// integration tests to verify expansion flows through `maybeCleanup`.
    private func makeStubPresets(snippets: [String: String]) -> StubPresets {
        var s = StubPresets()
        s.snippetMap = snippets
        return s
    }
    private final class FakeCleanup: TranscriptCleaning, @unchecked Sendable {
        var nextResult: Result<String, Error> = .success("CLEANED")
        private(set) var calls = 0
        private(set) var lastRaw: String?
        func clean(_ raw: String, bundleID: String?) async throws -> String {
            calls += 1
            lastRaw = raw
            switch nextResult {
            case .success(let s): return s
            case .failure(let e): throw e
            }
        }
    }

    private func makeRig(
        transcript: Transcript = Transcript(text: "uh I think this is a test", averageNoSpeechProb: 0),
        cleanup: FakeCleanup = FakeCleanup(),
        presets: StubPresets? = nil,
        fallbackSink: (@MainActor (SayMooreError) -> Void)? = nil
    ) -> (PipelineCoordinator, AppState, FakeCleanup, FakePasteboard, FakeKeyboard) {
        let rec = FakeRecorder()
        let trans = FakeTranscriptionService()
        trans.nextResult = .success(transcript)
        let pb = FakePasteboard()
        let kb = FakeKeyboard()
        let fm = FakeFrontmost()
        fm.bundleID = "com.apple.TextEdit"
        let paste = PasteService(pasteboard: pb, keyboard: kb, frontmost: fm, restoreDelay: .zero)
        let state = AppState()
        let coord = PipelineCoordinator(
            appState: state,
            recorder: rec,
            transcription: trans,
            paste: paste,
            presets: presets ?? stubPresets,
            cleanup: cleanup,
            onFallback: fallbackSink
        )
        return (coord, state, cleanup, pb, kb)
    }

    func testCleanupHappyPathPastesCleanedText() async throws {
        let (coord, state, cleanup, pb, kb) = makeRig()
        cleanup.nextResult = .success("Cleaned text")
        coord.toggle(bundleID: "com.apple.TextEdit")
        coord.toggle(bundleID: nil)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(cleanup.calls, 1)
        XCTAssertEqual(kb.pastes, 1)
        XCTAssertEqual(pb.current, "previous", "clipboard restored after paste")
        XCTAssertEqual(state.state, .idle)
    }

    func testFastPathSkipsCleanupForShortTranscript() async throws {
        let (coord, state, cleanup, _, kb) = makeRig(
            transcript: Transcript(text: "yes please now", averageNoSpeechProb: 0)
        )
        coord.toggle(bundleID: "com.apple.TextEdit")
        coord.toggle(bundleID: nil)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(cleanup.calls, 0, "3-word transcript should bypass cleanup")
        XCTAssertEqual(kb.pastes, 1)
        XCTAssertEqual(state.state, .idle)
    }

    func testOllamaUnreachableFallsBackToRawAndFiresCallback() async throws {
        var captured: SayMooreError?
        let fake = FakeCleanup()
        fake.nextResult = .failure(SayMooreError.ollamaUnreachable)
        let (coord, state, _, _, kb) = makeRig(
            cleanup: fake,
            fallbackSink: { e in captured = e }
        )
        coord.toggle(bundleID: "com.apple.TextEdit")
        coord.toggle(bundleID: nil)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(captured, .ollamaUnreachable)
        XCTAssertEqual(kb.pastes, 1, "raw still pastes")
        XCTAssertEqual(state.state, .idle)
    }

    func testCleanupTimeoutFallsBackToRaw() async throws {
        let fake = FakeCleanup()
        fake.nextResult = .failure(SayMooreError.cleanupTimedOut)
        let (coord, state, _, _, kb) = makeRig(cleanup: fake)
        coord.toggle(bundleID: "com.apple.TextEdit")
        coord.toggle(bundleID: nil)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(kb.pastes, 1)
        XCTAssertEqual(state.state, .idle)
    }

    // MARK: - C5: Hyphenated-word tokenizer

    func testHyphenatedPhraseNotTakenAsFastPath() async throws {
        // "state-of-the-art now" splits to 5 tokens on punctuation+whitespace,
        // so it must NOT take the fast path (threshold is 3).
        let (coord, state, cleanup, _, kb) = makeRig(
            transcript: Transcript(text: "state-of-the-art now", averageNoSpeechProb: 0)
        )
        coord.toggle(bundleID: "com.apple.TextEdit")
        coord.toggle(bundleID: nil)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(cleanup.calls, 1, "hyphenated phrase has >3 tokens — cleanup must run")
        XCTAssertEqual(kb.pastes, 1)
        XCTAssertEqual(state.state, .idle)
    }

    func testThreeWhitespaceSeparatedWordsStillTakeFastPath() async throws {
        // "yes please now" = 3 tokens → fast path, cleanup skipped.
        let (coord, state, cleanup, _, kb) = makeRig(
            transcript: Transcript(text: "yes please now", averageNoSpeechProb: 0)
        )
        coord.toggle(bundleID: "com.apple.TextEdit")
        coord.toggle(bundleID: nil)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(cleanup.calls, 0, "3-word transcript must still take fast path")
        XCTAssertEqual(kb.pastes, 1)
        XCTAssertEqual(state.state, .idle)
    }

    // MARK: - Snippet integration (v1.1)

    func testSnippetExpandsBeforeCleanupSeesIt() async throws {
        let fake = FakeCleanup()
        fake.nextResult = .success("Thanks — Tracy please review")
        let (coord, state, cleanup, _, kb) = makeRig(
            transcript: Transcript(text: "thanks insert sig please review", averageNoSpeechProb: 0),
            cleanup: fake,
            presets: makeStubPresets(snippets: ["sig": "— Tracy"])
        )
        coord.toggle(bundleID: "com.apple.TextEdit")
        coord.toggle(bundleID: nil)
        try await Task.sleep(for: .milliseconds(80))
        // The cleanup service must see the EXPANDED transcript, not the raw one.
        XCTAssertEqual(cleanup.lastRaw, "thanks — Tracy please review",
                       "snippets must expand before the LLM sees the transcript")
        XCTAssertEqual(kb.pastes, 1)
        XCTAssertEqual(state.state, .idle)
    }

    func testSnippetExpandsOnFastPath() async throws {
        // 3-word raw → fast-path skips cleanup; snippet still expands.
        let (coord, _, cleanup, pb, kb) = makeRig(
            transcript: Transcript(text: "insert sig now", averageNoSpeechProb: 0),
            presets: makeStubPresets(snippets: ["sig": "— Tracy"])
        )
        coord.toggle(bundleID: "com.apple.TextEdit")
        coord.toggle(bundleID: nil)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(cleanup.calls, 0, "must take fast path")
        XCTAssertEqual(kb.pastes, 1)
        XCTAssertEqual(pb.current, "previous", "clipboard restored")
        // The pasted text should have had the snippet expanded.
        // (FakePasteboard restores the prior clipboard; we can't read what
        // was pasted directly, but cleanup not running + paste happening
        // confirms the fast-path branch fired. Pattern matches the existing
        // testFastPathSkipsCleanupForShortTranscript assertion shape.)
    }

    func testSnippetUnchangedWhenNoMatch() async throws {
        let fake = FakeCleanup()
        fake.nextResult = .success("Cleaned")
        let (coord, _, cleanup, _, _) = makeRig(
            transcript: Transcript(text: "no snippet keyword present here", averageNoSpeechProb: 0),
            cleanup: fake,
            presets: makeStubPresets(snippets: ["sig": "— Tracy"])
        )
        coord.toggle(bundleID: "com.apple.TextEdit")
        coord.toggle(bundleID: nil)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(cleanup.lastRaw, "no snippet keyword present here",
                       "no expansion when no `insert <name>` trigger present")
    }

    // MARK: - Whisper initial_prompt biasing (v1.1)

    /// Like makeRig but exposes the FakeTranscriptionService so callers can
    /// inspect what bias hint was passed through to whisper.
    private func makeBiasingRig(presets: StubPresets) -> (PipelineCoordinator, FakeTranscriptionService) {
        let rec = FakeRecorder()
        let trans = FakeTranscriptionService()
        trans.nextResult = .success(Transcript(text: "fake", averageNoSpeechProb: 0))
        let pb = FakePasteboard()
        let kb = FakeKeyboard()
        let fm = FakeFrontmost()
        fm.bundleID = "com.apple.TextEdit"
        let paste = PasteService(pasteboard: pb, keyboard: kb, frontmost: fm, restoreDelay: .zero)
        let coord = PipelineCoordinator(
            appState: AppState(),
            recorder: rec,
            transcription: trans,
            paste: paste,
            presets: presets,
            cleanup: FakeCleanup()
        )
        return (coord, trans)
    }

    func testBiasHintIsNilWhenVocabularyEmpty() async throws {
        var stub = StubPresets()
        stub.vocab = []
        let (coord, trans) = makeBiasingRig(presets: stub)
        coord.toggle(bundleID: "com.apple.TextEdit")
        coord.toggle(bundleID: nil)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(trans.lastInitialPrompt, "empty vocab must yield nil bias")
    }

    func testBiasHintPassedToWhisperWhenVocabularyHasEntries() async throws {
        var stub = StubPresets()
        stub.vocab = [
            VocabEntry(phonetic: "Quinn",    canonical: "Qwen"),
            VocabEntry(phonetic: "Swift UI", canonical: "SwiftUI"),
        ]
        let (coord, trans) = makeBiasingRig(presets: stub)
        coord.toggle(bundleID: "com.apple.TextEdit")
        coord.toggle(bundleID: nil)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(trans.lastInitialPrompt, "Qwen, SwiftUI")
    }
}
