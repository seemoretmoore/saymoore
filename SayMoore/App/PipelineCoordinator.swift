import Foundation

@MainActor
final class PipelineCoordinator {
    static let fastPathMaxWordCount = 3
    /// Wall-clock seconds at which the "30 seconds remaining" colour cue (yellow pill) fires.
    static let defaultLengthCapCaution: TimeInterval = 60.0
    /// Wall-clock seconds at which the "10 seconds remaining" warning fires.
    static let defaultLengthCapWarning: TimeInterval = 80.0
    /// Wall-clock seconds at which recording is force-stopped.
    static let defaultLengthCapHardStop: TimeInterval = 90.0

    /// Time-remaining tint phase for the menu-bar pill. Cancel/stop returns to `.idle`;
    /// `.normal` fires immediately on record start (green); `.caution` at 60 s (yellow);
    /// `.warning` at 80 s alongside the existing length-cap banner (red).
    enum LengthCapPhase { case idle, normal, caution, warning }

    /// Seconds after a successful paste during which a fresh Ctrl-Ctrl PTT
    /// activation is interpreted as a Command Mode follow-up (voice edit
    /// instruction) instead of a fresh dictation. After this window the
    /// "last paste" state is cleared.
    static let defaultCommandModeWindow: TimeInterval = 5.0

    private let appState: AppState
    private let recorder: AudioRecording
    private let transcription: TranscriptionService
    private let cleanup: TranscriptCleaning?
    private let command: CommandRewriting?
    private let paste: PasteService
    private let presets: PresetResolving
    private let recordingsDir: URL?
    private let historyStore: HistoryStore?
    #if DEBUG
    private let persistRawWAV: Bool
    #endif
    private let onFallback: (@MainActor (SayMooreError) -> Void)?
    private let vadService: VADService?
    private let lengthCapCaution: TimeInterval
    private let lengthCapWarning: TimeInterval
    private let lengthCapHardStop: TimeInterval
    private let watchdogTimeout: TimeInterval
    private let commandModeWindow: TimeInterval
    private let streamingModeProvider: @MainActor @Sendable () -> StreamingMode
    private let hudPartialSink: (@MainActor (String, String) -> Void)?
    private var streamingTranscriber: StreamingTranscriber?

    private var capturedBundleID: String?
    /// Set when a recording is interpreted as a Command Mode edit (rewrite the
    /// prior paste) rather than a fresh dictation. Decided at toggle-start and
    /// carried through `processSamples` so the post-transcription branch
    /// routes to `CommandService` instead of `CleanupService`.
    private var captureIsCommandMode: Bool = false
    /// Most recent successful paste text + timestamp + bundleID. Cleared
    /// after `commandModeWindow` elapses or after the next dictation finishes.
    private var lastPastedText: String?
    private var lastPasteAt: ContinuousClock.Instant?
    private var lastPasteBundleID: String?
    private var processingTask: Task<Void, Never>?
    private var cautionTimerTask: Task<Void, Never>?
    private var warningTimerTask: Task<Void, Never>?
    private var hardStopTimerTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?

    /// When true, the pipeline refuses to start recording and posts the
    /// `.ollamaEndpointUntrusted` banner. Set by AppDelegate after the trust probe.
    var blocked: Bool = false

    /// Fired when a toggle hotkey arrives while the pipeline is mid-processing
    /// (`.transcribing` / `.cleaning` / `.pasting`) or while a previous
    /// `processingTask` is still in flight — i.e. the press is ignored because
    /// no state transition is possible. Used by `AudioFeedbackService.busy()`.
    /// Not fired for the `blocked` path (that has its own banner).
    var onBusyHotkey: (@MainActor () -> Void)?

    /// Fired whenever the length-cap colour phase changes — `.normal` on
    /// record start, `.caution` at the 60 s mark, `.warning` at 80 s (alongside
    /// the existing length-cap banner), and `.idle` on any exit from recording.
    /// Drives the MenuBarController pill tint.
    var onLengthCapPhase: (@MainActor (LengthCapPhase) -> Void)?

    /// v1.1 vocab auto-suggest. Fired with the just-pasted cleaned text so
    /// AppDelegate can run it through `VocabSuggester.consider` and post a
    /// suggestion banner. Decoupled from the suggester itself so the
    /// coordinator stays test-friendly (no notification side effects).
    var onPasteSucceeded: (@MainActor (String) -> Void)?

    #if DEBUG
    init(
        appState: AppState,
        recorder: AudioRecording,
        transcription: TranscriptionService,
        paste: PasteService,
        presets: PresetResolving,
        cleanup: TranscriptCleaning? = nil,
        command: CommandRewriting? = nil,
        recordingsDir: URL? = nil,
        persistRawWAV: Bool = false,
        vadService: VADService? = nil,
        historyStore: HistoryStore? = nil,
        lengthCapCaution: TimeInterval = PipelineCoordinator.defaultLengthCapCaution,
        lengthCapWarning: TimeInterval = PipelineCoordinator.defaultLengthCapWarning,
        lengthCapHardStop: TimeInterval = PipelineCoordinator.defaultLengthCapHardStop,
        watchdogTimeout: TimeInterval = 30,
        commandModeWindow: TimeInterval = PipelineCoordinator.defaultCommandModeWindow,
        streamingModeProvider: @escaping @MainActor @Sendable () -> StreamingMode = { .off },
        hudPartialSink: (@MainActor (String, String) -> Void)? = nil,
        onFallback: (@MainActor (SayMooreError) -> Void)? = nil
    ) {
        self.appState = appState
        self.recorder = recorder
        self.transcription = transcription
        self.cleanup = cleanup
        self.command = command
        self.paste = paste
        self.presets = presets
        self.recordingsDir = recordingsDir
        self.persistRawWAV = persistRawWAV
        self.vadService = vadService
        self.historyStore = historyStore
        self.lengthCapCaution = lengthCapCaution
        self.lengthCapWarning = lengthCapWarning
        self.lengthCapHardStop = lengthCapHardStop
        self.watchdogTimeout = watchdogTimeout
        self.commandModeWindow = commandModeWindow
        self.streamingModeProvider = streamingModeProvider
        self.hudPartialSink = hudPartialSink
        self.onFallback = onFallback
        wireVADIfNeeded()
    }
    #else
    init(
        appState: AppState,
        recorder: AudioRecording,
        transcription: TranscriptionService,
        paste: PasteService,
        presets: PresetResolving,
        cleanup: TranscriptCleaning? = nil,
        command: CommandRewriting? = nil,
        recordingsDir: URL? = nil,
        vadService: VADService? = nil,
        historyStore: HistoryStore? = nil,
        lengthCapCaution: TimeInterval = PipelineCoordinator.defaultLengthCapCaution,
        lengthCapWarning: TimeInterval = PipelineCoordinator.defaultLengthCapWarning,
        lengthCapHardStop: TimeInterval = PipelineCoordinator.defaultLengthCapHardStop,
        watchdogTimeout: TimeInterval = 30,
        commandModeWindow: TimeInterval = PipelineCoordinator.defaultCommandModeWindow,
        streamingModeProvider: @escaping @MainActor @Sendable () -> StreamingMode = { .off },
        hudPartialSink: (@MainActor (String, String) -> Void)? = nil,
        onFallback: (@MainActor (SayMooreError) -> Void)? = nil
    ) {
        self.appState = appState
        self.recorder = recorder
        self.transcription = transcription
        self.cleanup = cleanup
        self.command = command
        self.paste = paste
        self.presets = presets
        self.recordingsDir = recordingsDir
        self.vadService = vadService
        self.historyStore = historyStore
        self.lengthCapCaution = lengthCapCaution
        self.lengthCapWarning = lengthCapWarning
        self.lengthCapHardStop = lengthCapHardStop
        self.watchdogTimeout = watchdogTimeout
        self.commandModeWindow = commandModeWindow
        self.streamingModeProvider = streamingModeProvider
        self.hudPartialSink = hudPartialSink
        self.onFallback = onFallback
        wireVADIfNeeded()
    }
    #endif

    private func wireVADIfNeeded() {
        guard let vad = vadService else { return }
        recorder.vadService = vad
        // VADService fires the observer from its worker queue. Hop to the main
        // actor to mutate coordinator state.
        vad.silenceObserver = { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleSilenceAutoStop()
            }
        }
    }

    func toggle(bundleID: String?) {
        if blocked {
            Log.pipeline.error("Toggle blocked — Ollama endpoint untrusted")
            onFallback?(.ollamaEndpointUntrusted)
            return
        }
        if let t = processingTask, !t.isCancelled {
            Log.pipeline.debug("Toggle ignored — pipeline in flight")
            onBusyHotkey?()
            return
        }
        switch appState.state {
        case .idle:
            captureIsCommandMode = commandModeEligible(bundleID: bundleID)
            if captureIsCommandMode {
                Log.pipeline.info("toggle → command mode (prior paste within \(self.commandModeWindow, privacy: .public)s)")
            }
            beginRecording(bundleID: bundleID)
        case .recording:
            cancelLengthCapTimers()
            let samples: [Float]
            do {
                samples = try recorder.stop()
            } catch {
                Log.audio.error("recorder.stop failed: \(String(describing: error), privacy: .public)")
                transitionToError(error)
                return
            }
            armWatchdog()
            appState.transition(to: .transcribing)
            processingTask = Task {
                await self.stopStreaming()
                await self.processSamples(samples)
            }
        default:
            Log.pipeline.debug("Toggle ignored in state \(String(describing: self.appState.state), privacy: .public)")
            onBusyHotkey?()
        }
    }

    /// Invoked by AudioRecorder.onDeviceChange when AVAudioEngine posted a
    /// configurationChangeNotification mid-recording. The recorder has already
    /// stopped itself; we surface the abort to the user and reset state.
    func handleAudioDeviceChange() {
        guard appState.state == .recording else { return }
        Log.pipeline.error("audio device changed mid-recording")
        cancelLengthCapTimers()
        cancelWatchdog()
        Task { await stopStreaming() }
        capturedBundleID = nil
        let err = SayMooreError.audioEngineFailed(underlying: AudioRecorder.RecorderError.deviceChanged)
        onFallback?(err)
        appState.transition(to: .error(err))
        appState.transition(to: .idle)
    }

    func cancel() {
        guard appState.state == .recording else { return }
        recorder.cancel()
        Task { await stopStreaming() }
        cancelLengthCapTimers()
        cancelWatchdog()
        capturedBundleID = nil
        captureIsCommandMode = false
        appState.transition(to: .idle)
        Log.pipeline.info("Recording cancelled via Esc")
    }

    /// True when a fresh Ctrl-Ctrl PTT activation should be interpreted as
    /// a Command Mode rewrite of the prior paste. Requires:
    ///   1. CommandRewriting service was injected (feature enabled).
    ///   2. A successful paste happened within the window.
    ///   3. The frontmost bundleID still matches the bundle that received
    ///      the prior paste (cross-app PTT clears Command Mode eligibility).
    private func commandModeEligible(bundleID: String?) -> Bool {
        guard command != nil,
              let lastText = lastPastedText, !lastText.isEmpty,
              let lastAt = lastPasteAt else {
            return false
        }
        let elapsed = ContinuousClock.now - lastAt
        guard elapsed <= .seconds(commandModeWindow) else {
            // Window expired — purge state so a stale paste from minutes ago
            // never re-triggers later.
            clearLastPaste()
            return false
        }
        guard bundleID != nil, bundleID == lastPasteBundleID else {
            return false
        }
        return true
    }

    private func clearLastPaste() {
        lastPastedText = nil
        lastPasteAt = nil
        lastPasteBundleID = nil
    }

    // MARK: - Streaming partials (v1.2)

    private func startStreamingIfEnabled() {
        let mode = streamingModeProvider()
        guard mode != .off else { return }
        let s = StreamingTranscriber(transcription: transcription, mode: mode)
        let sink = hudPartialSink
        s.onPartialUpdate = { committed, active in
            sink?(committed, active)
        }
        recorder.onSamples = { samples in
            s.appendSamples(samples)
        }
        s.start()
        streamingTranscriber = s
        Log.pipeline.info("streaming partials enabled (mode=\(mode.rawValue, privacy: .public))")
    }

    private func stopStreaming() async {
        if let s = streamingTranscriber {
            await s.stop()
            streamingTranscriber = nil
            recorder.onSamples = nil
        }
    }

    private func beginRecording(bundleID: String?) {
        capturedBundleID = bundleID
        do {
            try recorder.start()
            startStreamingIfEnabled()
            appState.transition(to: .recording)
            // Recording length is gated by the length-cap timers (60/80/90s).
            // The watchdog covers only the post-recording pipeline phases
            // (transcribing/cleaning/pasting) where a hang is non-obvious; it
            // is armed at each .recording → .transcribing transition.
            armLengthCapTimers()
        } catch {
            Log.audio.error("recorder.start failed: \(String(describing: error), privacy: .public)")
            transitionToError(error)
        }
    }

    // MARK: - Global watchdog (one timer covers the whole start→idle run)

    private func armWatchdog() {
        cancelWatchdog()
        let t = watchdogTimeout
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(t * 1_000_000_000))
            await MainActor.run { self?.fireWatchdog() }
        }
    }

    private func cancelWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    private func fireWatchdog() {
        guard appState.state != .idle else { return }
        Log.pipeline.fault("watchdog fired in state \(String(describing: self.appState.state), privacy: .public)")
        // If the watchdog fired mid-recording, the engine is still installed and
        // the ring buffer is still accumulating. Tear it down — otherwise the
        // NEXT recorder.start() early-returns on isRecording, skips the buffer
        // reset, and the next stop() drains session N-1 + silence + session N
        // (whisper hallucinates tech-bro words on the silence gap).
        recorder.cancel()
        Task { await stopStreaming() }
        capturedBundleID = nil
        captureIsCommandMode = false
        processingTask?.cancel()
        processingTask = nil
        cancelLengthCapTimers()
        onFallback?(.watchdogTimeout)
        appState.transition(to: .error(.watchdogTimeout))
        appState.transition(to: .idle)
    }

    /// Called by the VAD silence observer (post main-actor hop) when accumulated
    /// silence first crosses VADService's threshold during recording.
    private func handleSilenceAutoStop() {
        guard appState.state == .recording else {
            Log.pipeline.debug("VAD silence fired outside .recording — ignoring")
            return
        }
        Log.pipeline.info("VAD silence threshold crossed — auto-stopping")
        cancelLengthCapTimers()
        let samples: [Float]
        do {
            samples = try recorder.stop()
        } catch {
            Log.audio.error("recorder.stop failed during VAD auto-stop: \(String(describing: error), privacy: .public)")
            transitionToError(error)
            return
        }
        armWatchdog()
        appState.transition(to: .transcribing)
        processingTask = Task {
            await self.stopStreaming()
            await self.processSamples(samples)
        }
    }

    // MARK: - Length cap (80s warning / 90s hard stop)

    private func armLengthCapTimers() {
        cancelLengthCapTimers()
        onLengthCapPhase?(.normal)
        let caution = lengthCapCaution
        let warning = lengthCapWarning
        let hard = lengthCapHardStop
        cautionTimerTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(caution * 1_000_000_000))
            } catch { return }
            self?.fireLengthCapCaution()
        }
        warningTimerTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(warning * 1_000_000_000))
            } catch { return }
            self?.fireLengthCapWarning()
        }
        hardStopTimerTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(hard * 1_000_000_000))
            } catch { return }
            self?.fireLengthCapHardStop()
        }
    }

    private func cancelLengthCapTimers() {
        cautionTimerTask?.cancel()
        cautionTimerTask = nil
        warningTimerTask?.cancel()
        warningTimerTask = nil
        hardStopTimerTask?.cancel()
        hardStopTimerTask = nil
        onLengthCapPhase?(.idle)
    }

    private func fireLengthCapCaution() {
        guard appState.state == .recording else { return }
        Log.pipeline.info("length cap caution fired (\(self.lengthCapCaution, privacy: .public)s) — 30s remaining")
        onLengthCapPhase?(.caution)
    }

    private func fireLengthCapWarning() {
        guard appState.state == .recording else { return }
        Log.pipeline.info("length cap warning fired (\(self.lengthCapWarning, privacy: .public)s)")
        onLengthCapPhase?(.warning)
        onFallback?(.recordingLengthWarning)
    }

    private func fireLengthCapHardStop() {
        guard appState.state == .recording else { return }
        Log.pipeline.info("length cap hard-stop fired (\(self.lengthCapHardStop, privacy: .public)s)")
        let samples: [Float]
        do {
            samples = try recorder.stop()
        } catch {
            // recordingTooLong from ring overflow shouldn't happen before our 90s cap,
            // but if anything else fails surface it normally.
            transitionToError(error)
            return
        }
        // Post the "stopped early" banner before processing kicks off.
        onFallback?(.recordingTooLong)
        armWatchdog()
        appState.transition(to: .transcribing)
        processingTask = Task {
            await self.stopStreaming()
            await self.processSamples(samples)
        }
    }

    private func processSamples(_ samples: [Float]) async {
        defer {
            processingTask = nil
            cancelWatchdog()
            Log.pipeline.debug("processingTask cleared")
        }

        #if DEBUG
        if persistRawWAV, let dir = recordingsDir {
            let url = RecordingPaths.newRecordingURL(in: dir)
            try? AudioRecorder.writeWAV(samples: samples, to: url)
            Log.pipeline.debug("debug WAV → \(url.path, privacy: .public)")
        }
        #endif

        let transcript: Transcript
        do {
            // v1.1: bias whisper acoustic recognition toward known proper nouns
            // (vocabulary canonicals) so terms like "FSEventStream" / "Qwen"
            // transcribe correctly the first time, before the deterministic
            // post-substitution path even runs.
            let bias = PresetStore.biasHint(from: presets.vocabulary())
            transcript = try await transcription.transcribe(
                samples: samples,
                sampleRate: 16_000,
                initialPrompt: bias
            )
        } catch {
            Log.transcribe.error("transcription failed: \(String(describing: error), privacy: .public)")
            transitionToError(error)
            return
        }

        if transcript.isGarbage {
            Log.transcribe.info("transcript flagged garbage (avgNoSpeechProb=\(transcript.averageNoSpeechProb, privacy: .public))")
            transitionToError(SayMooreError.transcriptionGarbage)
            return
        }
        if transcript.text.isEmpty {
            Log.transcribe.info("transcript is empty — nothing to paste")
            appState.transition(to: .idle)
            capturedBundleID = nil
            captureIsCommandMode = false
            return
        }

        // Command Mode: route to CommandService instead of the cleanup +
        // paste flow. Re-validate the window here — transcription can take
        // a few hundred ms, so an edge-case dictation that ran right at the
        // window boundary might still be valid. If the window or focus
        // moved, fall through to a normal paste of the transcript (better
        // to do something than swallow the user's words).
        if captureIsCommandMode, let cmd = command, let original = lastPastedText {
            await runCommandMode(
                originalText: original,
                instruction: transcript.text,
                command: cmd
            )
            return
        }

        // M3: belt-and-braces — re-check blocked before the LLM cleanup step.
        // The probe may have completed (and set blocked = true) while transcription
        // was in flight. Abort cleanly rather than sending audio to an untrusted Ollama.
        if blocked {
            Log.pipeline.error("processSamples: blocked became true mid-pipeline — aborting")
            transitionToError(SayMooreError.ollamaEndpointUntrusted)
            return
        }

        let cleaned = await maybeCleanup(raw: transcript.text)

        appState.transition(to: .pasting)
        do {
            try await paste.paste(transcript: cleaned, capturedBundleID: capturedBundleID)
            // Stash for Command Mode eligibility on the next PTT activation.
            lastPastedText = cleaned
            lastPasteAt = ContinuousClock.now
            lastPasteBundleID = capturedBundleID
            // v1.1 vocab auto-suggest hook. Coordinator fires the callback;
            // AppDelegate owns the VocabSuggester + the notification surface.
            onPasteSucceeded?(cleaned)

            let duration = Double(samples.count) / 16_000.0
            let chosenText = cleaned.isEmpty ? transcript.text : cleaned
            let wordCount = chosenText
                .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
                .count
            let entry = HistoryEntry(
                schemaVersion: HistoryEntry.currentSchemaVersion,
                id: UUID(),
                timestamp: Date(),
                durationSeconds: duration,
                rawTranscript: transcript.text,
                cleanedTranscript: cleaned == transcript.text ? nil : cleaned,
                bundleID: capturedBundleID,
                wordCount: wordCount
            )
            do {
                try await historyStore?.append(entry)
            } catch {
                Log.pipeline.error("history append failed: \(error.localizedDescription, privacy: .public)")
            }
        } catch let e as SayMooreError {
            Log.paste.error("paste failed: \(String(describing: e), privacy: .public)")
            appState.transition(to: .error(e))
            onFallback?(e)
        } catch {
            Log.paste.error("paste failed: \(String(describing: error), privacy: .public)")
            appState.transition(to: .error(.pasteInjectionFailed))
            onFallback?(.pasteInjectionFailed)
        }

        capturedBundleID = nil
        captureIsCommandMode = false
        appState.transition(to: .idle)
    }

    /// Command Mode pipeline: send the prior paste + the user's voice
    /// instruction to `CommandService`, then post Cmd-Z + paste the rewritten
    /// text in place via `PasteService.replacePriorPaste`. On rewrite failure,
    /// the prior paste is left untouched (we never sent Cmd-Z); the user gets
    /// a banner and the original text stays on screen.
    private func runCommandMode(originalText: String, instruction: String, command: CommandRewriting) async {
        appState.transition(to: .cleaning)
        let rewritten: String
        do {
            rewritten = try await command.rewrite(original: originalText, instruction: instruction)
        } catch let e as SayMooreError {
            Log.cleanup.error("command-rewrite failed: \(String(describing: e), privacy: .public)")
            onFallback?(e)
            // Leave lastPasted* untouched — user can re-invoke Command Mode
            // with a clearer instruction within the remaining window.
            captureIsCommandMode = false
            capturedBundleID = nil
            appState.transition(to: .error(e))
            appState.transition(to: .idle)
            return
        } catch {
            Log.cleanup.error("command-rewrite unexpected error: \(String(describing: error), privacy: .public)")
            let e = SayMooreError.commandRewriteFailed(reason: "unexpected")
            onFallback?(e)
            captureIsCommandMode = false
            capturedBundleID = nil
            appState.transition(to: .error(e))
            appState.transition(to: .idle)
            return
        }

        appState.transition(to: .pasting)
        do {
            try await paste.replacePriorPaste(rewritten: rewritten, capturedBundleID: capturedBundleID)
            // Update last-paste state to the new text so the user can
            // chain rewrites ("make it shorter" → "now add a question mark").
            lastPastedText = rewritten
            lastPasteAt = ContinuousClock.now
            lastPasteBundleID = capturedBundleID
        } catch let e as SayMooreError {
            Log.paste.error("command-mode paste failed: \(String(describing: e), privacy: .public)")
            onFallback?(e)
            appState.transition(to: .error(e))
        } catch {
            Log.paste.error("command-mode paste failed: \(String(describing: error), privacy: .public)")
            onFallback?(.pasteInjectionFailed)
            appState.transition(to: .error(.pasteInjectionFailed))
        }

        captureIsCommandMode = false
        capturedBundleID = nil
        appState.transition(to: .idle)
    }

    private func maybeCleanup(raw: String) async -> String {
        // Snippets expand BEFORE the LLM so cleanup can adjust grammar around
        // the inserted value. Applied on every dictation path (fast-path
        // skips cleanup, but it still gets snippet expansion via this hop;
        // fallback-to-raw paths return the post-snippet raw text). Command
        // Mode skips this entirely — `runCommandMode` is a separate branch.
        let withSnippets = PresetStore.expandSnippets(in: raw, snippets: presets.snippets())
        let cleaned = await runCleanup(raw: withSnippets)
        // Deterministic phonetic→canonical substitution. Applies on every path
        // (LLM-cleaned, fast-path, fallback-to-raw) so vocabulary takes effect
        // even when the cleanup LLM times out or is unreachable.
        return PresetStore.applyVocabSubstitutions(to: cleaned, vocab: presets.vocabulary())
    }

    private func runCleanup(raw: String) async -> String {
        guard let cleanup else { return raw }

        let separators = CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)
        let words = raw.components(separatedBy: separators).filter { !$0.isEmpty }.count
        if words <= Self.fastPathMaxWordCount {
            Log.cleanup.info("fast-path: \(words, privacy: .public) words ≤ \(Self.fastPathMaxWordCount, privacy: .public), skipping cleanup")
            return raw
        }

        appState.transition(to: .cleaning)
        do {
            return try await cleanup.clean(raw, bundleID: capturedBundleID)
        } catch let e as SayMooreError where e.fallsBackToRaw {
            Log.cleanup.error("cleanup fell back to raw: \(String(describing: e), privacy: .public)")
            onFallback?(e)
            return raw
        } catch {
            Log.cleanup.error("cleanup unexpected error, falling back to raw: \(String(describing: error), privacy: .public)")
            onFallback?(.cleanupFailed(underlying: error))
            return raw
        }
    }

    private func transitionToError(_ error: Error) {
        cancelWatchdog()
        capturedBundleID = nil
        captureIsCommandMode = false
        cancelLengthCapTimers()
        if let smError = error as? SayMooreError {
            appState.transition(to: .error(smError))
            // onFallback is the single error→banner path. Originally cleanup-only;
            // widened so silentCapture / recordingTooLong / paste errors also surface.
            onFallback?(smError)
        }
        appState.transition(to: .idle)
    }
}
