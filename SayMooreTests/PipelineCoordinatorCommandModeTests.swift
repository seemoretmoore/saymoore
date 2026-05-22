import XCTest
@testable import SayMoore

@MainActor
final class PipelineCoordinatorCommandModeTests: XCTestCase {

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
        func preset(for bundleID: String?) -> Preset {
            Preset(name: "stub", promptTemplate: "{{transcript}}")
        }
        func vocabulary() -> [VocabEntry] { [] }
    }
    private final class FakeCleanup: TranscriptCleaning, @unchecked Sendable {
        var nextResult: Result<String, Error> = .success("CLEANED")
        private(set) var calls = 0
        func clean(_ raw: String, bundleID: String?) async throws -> String {
            calls += 1
            switch nextResult {
            case .success(let s): return s
            case .failure(let e): throw e
            }
        }
    }
    private final class FakeCommand: CommandRewriting, @unchecked Sendable {
        var nextResult: Result<String, Error> = .success("REWRITTEN")
        private(set) var calls = 0
        private(set) var lastOriginal: String?
        private(set) var lastInstruction: String?
        func rewrite(original: String, instruction: String) async throws -> String {
            calls += 1
            lastOriginal = original
            lastInstruction = instruction
            switch nextResult {
            case .success(let s): return s
            case .failure(let e): throw e
            }
        }
    }

    private struct Rig {
        let coord: PipelineCoordinator
        let state: AppState
        let cleanup: FakeCleanup
        let command: FakeCommand
        let pb: FakePasteboard
        let kb: FakeKeyboard
    }

    private func makeRig(
        cleanedText: String = "Hello world how are you doing today",
        commandWindow: TimeInterval = 5.0,
        fallbackSink: (@MainActor (SayMooreError) -> Void)? = nil
    ) -> Rig {
        let rec = FakeRecorder()
        let trans = FakeTranscriptionService()
        trans.nextResult = .success(
            Transcript(text: cleanedText, averageNoSpeechProb: 0)
        )
        let pb = FakePasteboard()
        let kb = FakeKeyboard()
        let fm = FakeFrontmost()
        fm.bundleID = "com.apple.TextEdit"
        let paste = PasteService(pasteboard: pb, keyboard: kb, frontmost: fm, restoreDelay: .zero)
        let cleanup = FakeCleanup()
        cleanup.nextResult = .success(cleanedText)
        let command = FakeCommand()
        let state = AppState()
        let coord = PipelineCoordinator(
            appState: state,
            recorder: rec,
            transcription: trans,
            paste: paste,
            presets: StubPresets(),
            cleanup: cleanup,
            command: command,
            commandModeWindow: commandWindow,
            onFallback: fallbackSink
        )
        return Rig(coord: coord, state: state, cleanup: cleanup, command: command, pb: pb, kb: kb)
    }

    /// Drive a complete dictation+paste cycle so the coordinator stashes
    /// lastPastedText/At/BundleID. Returns after the pipeline lands back in .idle.
    private func performInitialPaste(_ rig: Rig, bundleID: String = "com.apple.TextEdit") async throws {
        rig.coord.toggle(bundleID: bundleID)
        rig.coord.toggle(bundleID: nil)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(rig.state.state, .idle, "initial paste must complete to .idle")
        XCTAssertEqual(rig.kb.pastes, 1)
    }

    func testFirstActivationIsNotCommandMode() async throws {
        let rig = makeRig()
        // No prior paste — first toggle is always a normal dictation.
        rig.coord.toggle(bundleID: "com.apple.TextEdit")
        rig.coord.toggle(bundleID: nil)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(rig.command.calls, 0)
        XCTAssertEqual(rig.kb.pastes, 1)
        XCTAssertEqual(rig.kb.undos, 0, "no undo on a normal dictation")
    }

    func testSecondActivationWithinWindowEntersCommandMode() async throws {
        let rig = makeRig()
        try await performInitialPaste(rig)

        rig.command.nextResult = .success("Updated text after rewrite.")
        rig.coord.toggle(bundleID: "com.apple.TextEdit")
        rig.coord.toggle(bundleID: nil)
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(rig.command.calls, 1, "second activation must route to command service")
        XCTAssertEqual(rig.cleanup.calls, 1, "cleanup ran once (initial paste only)")
        XCTAssertEqual(rig.kb.undos, 1, "command-mode posts Cmd-Z")
        XCTAssertEqual(rig.kb.pastes, 2, "rewritten text was pasted after undo")
        XCTAssertEqual(rig.state.state, .idle)
    }

    func testCommandModePassesInstructionAndOriginal() async throws {
        let rig = makeRig(cleanedText: "Hello world how are you")
        try await performInitialPaste(rig)

        rig.command.nextResult = .success("OK!")
        rig.coord.toggle(bundleID: "com.apple.TextEdit")
        rig.coord.toggle(bundleID: nil)
        try await Task.sleep(for: .milliseconds(120))

        // The original is the prior paste text; the instruction is the
        // most recent transcript.
        XCTAssertEqual(rig.command.lastOriginal, "Hello world how are you")
        XCTAssertEqual(rig.command.lastInstruction, "Hello world how are you")
    }

    func testCommandModeExpiresAfterWindow() async throws {
        let rig = makeRig(commandWindow: 0.05) // 50 ms window
        try await performInitialPaste(rig)
        // Sleep past the window.
        try await Task.sleep(for: .milliseconds(120))

        rig.coord.toggle(bundleID: "com.apple.TextEdit")
        rig.coord.toggle(bundleID: nil)
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(rig.command.calls, 0, "second activation past window must NOT enter command mode")
        XCTAssertEqual(rig.kb.undos, 0)
        XCTAssertEqual(rig.kb.pastes, 2, "two normal pastes total")
    }

    func testCommandModeRequiresSameBundle() async throws {
        let rig = makeRig()
        try await performInitialPaste(rig, bundleID: "com.apple.TextEdit")

        // Second toggle from a DIFFERENT app — not command-mode-eligible.
        rig.coord.toggle(bundleID: "com.tinyspeck.slackmacgap")
        rig.coord.toggle(bundleID: nil)
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(rig.command.calls, 0, "cross-app PTT must NOT enter command mode")
        XCTAssertEqual(rig.kb.undos, 0)
    }

    func testCommandRewriteFailureLeavesPriorPasteIntact() async throws {
        var captured: SayMooreError?
        let rig = makeRig(fallbackSink: { e in captured = e })
        try await performInitialPaste(rig)

        rig.command.nextResult = .failure(SayMooreError.commandRewriteFailed(reason: "placeholder"))
        rig.coord.toggle(bundleID: "com.apple.TextEdit")
        rig.coord.toggle(bundleID: nil)
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(rig.kb.undos, 0, "no Cmd-Z when rewrite fails — prior paste must stay intact")
        XCTAssertEqual(rig.kb.pastes, 1, "only the initial paste happened")
        XCTAssertEqual(rig.state.state, .idle)
        switch captured {
        case .commandRewriteFailed: break
        default: XCTFail("expected commandRewriteFailed banner, got \(String(describing: captured))")
        }
    }

    func testChainedRewritesUpdateLastPastedText() async throws {
        let rig = makeRig()
        try await performInitialPaste(rig)

        // First rewrite.
        rig.command.nextResult = .success("First rewrite text here now")
        rig.coord.toggle(bundleID: "com.apple.TextEdit")
        rig.coord.toggle(bundleID: nil)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(rig.command.calls, 1)

        // Second rewrite — should be eligible since the rewrite-paste also
        // refreshes lastPasteAt + lastPastedText.
        rig.command.nextResult = .success("Second rewrite text final form")
        rig.coord.toggle(bundleID: "com.apple.TextEdit")
        rig.coord.toggle(bundleID: nil)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(rig.command.calls, 2, "chained rewrites must enter command mode again")
        XCTAssertEqual(rig.command.lastOriginal, "First rewrite text here now",
                       "second rewrite must see the FIRST rewrite as its original")
        XCTAssertEqual(rig.kb.undos, 2)
    }
}
