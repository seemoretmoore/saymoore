import Foundation

@MainActor
final class PipelineCoordinator {
    static let fastPathMaxWordCount = 3

    private let appState: AppState
    private let recorder: AudioRecording
    private let transcription: TranscriptionService
    private let cleanup: TranscriptCleaning?
    private let paste: PasteService
    private let recordingsDir: URL?
    private let persistRawWAV: Bool
    private let onFallback: (@MainActor (SayMooreError) -> Void)?

    private var capturedBundleID: String?
    private var processingTask: Task<Void, Never>?

    init(
        appState: AppState,
        recorder: AudioRecording,
        transcription: TranscriptionService,
        paste: PasteService,
        cleanup: TranscriptCleaning? = nil,
        recordingsDir: URL? = nil,
        persistRawWAV: Bool = false,
        onFallback: (@MainActor (SayMooreError) -> Void)? = nil
    ) {
        self.appState = appState
        self.recorder = recorder
        self.transcription = transcription
        self.cleanup = cleanup
        self.paste = paste
        self.recordingsDir = recordingsDir
        self.persistRawWAV = persistRawWAV
        self.onFallback = onFallback
    }

    func toggle(bundleID: String?) {
        if let t = processingTask, !t.isCancelled {
            Log.pipeline.debug("Toggle ignored — pipeline in flight")
            return
        }
        switch appState.state {
        case .idle:
            beginRecording(bundleID: bundleID)
        case .recording:
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
        capturedBundleID = nil
        appState.transition(to: .idle)
        Log.pipeline.info("Recording cancelled via Esc")
    }

    private func beginRecording(bundleID: String?) {
        capturedBundleID = bundleID
        do {
            try recorder.start()
            appState.transition(to: .recording)
        } catch {
            Log.audio.error("recorder.start failed: \(String(describing: error), privacy: .public)")
            transitionToError(error)
        }
    }

    private func processSamples(_ samples: [Float]) async {
        defer { processingTask = nil }

        if persistRawWAV, let dir = recordingsDir {
            let url = RecordingPaths.newRecordingURL(in: dir)
            try? AudioRecorder.writeWAV(samples: samples, to: url)
            Log.pipeline.debug("debug WAV → \(url.path, privacy: .public)")
        }

        let transcript: Transcript
        do {
            transcript = try await transcription.transcribe(samples: samples, sampleRate: 16_000)
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

        let cleaned = await maybeCleanup(raw: transcript.text)

        appState.transition(to: .pasting)
        do {
            try await paste.paste(transcript: cleaned, capturedBundleID: capturedBundleID)
        } catch let e as SayMooreError {
            Log.paste.error("paste failed: \(String(describing: e), privacy: .public)")
            appState.transition(to: .error(e))
        } catch {
            Log.paste.error("paste failed: \(String(describing: error), privacy: .public)")
            appState.transition(to: .error(.pasteInjectionFailed))
        }

        capturedBundleID = nil
        appState.transition(to: .idle)
    }

    private func maybeCleanup(raw: String) async -> String {
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
        if let smError = error as? SayMooreError {
            appState.transition(to: .error(smError))
        }
        capturedBundleID = nil
        appState.transition(to: .idle)
    }
}
