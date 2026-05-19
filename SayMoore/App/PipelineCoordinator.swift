import Foundation

@MainActor
final class PipelineCoordinator {
    static let fastPathMaxWordCount = 3
    /// Wall-clock seconds at which the "10 seconds remaining" warning fires.
    static let defaultLengthCapWarning: TimeInterval = 80.0
    /// Wall-clock seconds at which recording is force-stopped.
    static let defaultLengthCapHardStop: TimeInterval = 90.0

    private let appState: AppState
    private let recorder: AudioRecording
    private let transcription: TranscriptionService
    private let cleanup: TranscriptCleaning?
    private let paste: PasteService
    private let presets: PresetResolving
    private let recordingsDir: URL?
    #if DEBUG
    private let persistRawWAV: Bool
    #endif
    private let onFallback: (@MainActor (SayMooreError) -> Void)?
    private let vadService: VADService?
    private let lengthCapWarning: TimeInterval
    private let lengthCapHardStop: TimeInterval

    private var capturedBundleID: String?
    private var processingTask: Task<Void, Never>?
    private var warningTimerTask: Task<Void, Never>?
    private var hardStopTimerTask: Task<Void, Never>?

    /// When true, the pipeline refuses to start recording and posts the
    /// `.ollamaEndpointUntrusted` banner. Set by AppDelegate after the trust probe.
    var blocked: Bool = false

    #if DEBUG
    init(
        appState: AppState,
        recorder: AudioRecording,
        transcription: TranscriptionService,
        paste: PasteService,
        presets: PresetResolving,
        cleanup: TranscriptCleaning? = nil,
        recordingsDir: URL? = nil,
        persistRawWAV: Bool = false,
        vadService: VADService? = nil,
        lengthCapWarning: TimeInterval = PipelineCoordinator.defaultLengthCapWarning,
        lengthCapHardStop: TimeInterval = PipelineCoordinator.defaultLengthCapHardStop,
        onFallback: (@MainActor (SayMooreError) -> Void)? = nil
    ) {
        self.appState = appState
        self.recorder = recorder
        self.transcription = transcription
        self.cleanup = cleanup
        self.paste = paste
        self.presets = presets
        self.recordingsDir = recordingsDir
        self.persistRawWAV = persistRawWAV
        self.vadService = vadService
        self.lengthCapWarning = lengthCapWarning
        self.lengthCapHardStop = lengthCapHardStop
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
        recordingsDir: URL? = nil,
        vadService: VADService? = nil,
        lengthCapWarning: TimeInterval = PipelineCoordinator.defaultLengthCapWarning,
        lengthCapHardStop: TimeInterval = PipelineCoordinator.defaultLengthCapHardStop,
        onFallback: (@MainActor (SayMooreError) -> Void)? = nil
    ) {
        self.appState = appState
        self.recorder = recorder
        self.transcription = transcription
        self.cleanup = cleanup
        self.paste = paste
        self.presets = presets
        self.recordingsDir = recordingsDir
        self.vadService = vadService
        self.lengthCapWarning = lengthCapWarning
        self.lengthCapHardStop = lengthCapHardStop
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
            return
        }
        switch appState.state {
        case .idle:
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
            appState.transition(to: .transcribing)
            processingTask = Task { await self.processSamples(samples) }
        default:
            Log.pipeline.debug("Toggle ignored in state \(String(describing: self.appState.state), privacy: .public)")
        }
    }

    func cancel() {
        guard appState.state == .recording else { return }
        recorder.cancel()
        cancelLengthCapTimers()
        capturedBundleID = nil
        appState.transition(to: .idle)
        Log.pipeline.info("Recording cancelled via Esc")
    }

    private func beginRecording(bundleID: String?) {
        capturedBundleID = bundleID
        do {
            try recorder.start()
            appState.transition(to: .recording)
            armLengthCapTimers()
        } catch {
            Log.audio.error("recorder.start failed: \(String(describing: error), privacy: .public)")
            transitionToError(error)
        }
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
        appState.transition(to: .transcribing)
        processingTask = Task { await self.processSamples(samples) }
    }

    // MARK: - Length cap (80s warning / 90s hard stop)

    private func armLengthCapTimers() {
        cancelLengthCapTimers()
        let warning = lengthCapWarning
        let hard = lengthCapHardStop
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
        warningTimerTask?.cancel()
        warningTimerTask = nil
        hardStopTimerTask?.cancel()
        hardStopTimerTask = nil
    }

    private func fireLengthCapWarning() {
        guard appState.state == .recording else { return }
        Log.pipeline.info("length cap warning fired (\(self.lengthCapWarning, privacy: .public)s)")
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
        appState.transition(to: .transcribing)
        processingTask = Task { await self.processSamples(samples) }
    }

    private func processSamples(_ samples: [Float]) async {
        defer {
            processingTask = nil
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
            transcript = try await transcription.transcribe(
                samples: samples,
                sampleRate: 16_000
            )
        } catch {
            Log.transcribe.error("transcription failed: \(String(describing: error), privacy: .public)")
            transitionToError(error)
            return
        }

        if transcript.isGarbage {
            Log.transcribe.info("transcript flagged garbage (avgNoSpeechProb=\(transcript.averageNoSpeechProb, privacy: .public))")
            appState.transition(to: .error(.transcriptionGarbage))
            appState.transition(to: .idle)
            capturedBundleID = nil
            return
        }
        if transcript.text.isEmpty {
            Log.transcribe.info("transcript is empty — nothing to paste")
            appState.transition(to: .idle)
            capturedBundleID = nil
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
        appState.transition(to: .idle)
    }

    private func maybeCleanup(raw: String) async -> String {
        let cleaned = await runCleanup(raw: raw)
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
        capturedBundleID = nil
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
