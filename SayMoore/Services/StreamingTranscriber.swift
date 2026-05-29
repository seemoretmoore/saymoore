import Foundation

/// Drives sliding-window whisper inference for live partial display. One
/// instance per recording; reuses the existing WhisperTranscriptionService
/// context (no second model load).
///
/// Concurrency: `appendSamples` is `nonisolated` and may be called from any
/// thread (audio thread) — it writes to a lock-protected `[Float]` field
/// synchronously, no actor hop. Lifecycle methods and `onPartialUpdate` are
/// main-actor. Inference runs on the whisper service's serial DispatchQueue,
/// which naturally serializes with the final `transcribe()` call invoked by
/// PipelineCoordinator.
@MainActor
final class StreamingTranscriber {
    private let transcription: TranscriptionService
    private let mode: StreamingMode

    // Lock-protected sample buffer. Accessed from the audio thread via
    // `appendSamples` (nonisolated) and from the main actor via `tick()`.
    private let bufferLock = NSLock()
    nonisolated(unsafe) private var samples: [Float] = []

    private var committedText: String = ""
    private var committedSampleOffset: Int = 0
    private var disabled: Bool = false
    private var tickTask: Task<Void, Never>?
    private var inFlight: Task<Void, Never>?

    /// Fired on the main actor after each successful pass.
    /// `committed` is the frozen prefix; `active` is the still-revisable tail.
    var onPartialUpdate: ((String, String) -> Void)?

    init(transcription: TranscriptionService, mode: StreamingMode) {
        precondition(mode != .off, "StreamingTranscriber must not be constructed for .off mode")
        self.transcription = transcription
        self.mode = mode
    }

    func start() {
        guard tickTask == nil else { return }
        let interval = mode.intervalSeconds
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.tick()
            }
        }
    }

    func stop() async {
        tickTask?.cancel()
        tickTask = nil
        if let inFlight {
            _ = await inFlight.value
        }
        inFlight = nil
    }

    /// Called from the audio thread (AudioRecorder.onSamples). Writes
    /// synchronously to the lock-protected buffer.
    nonisolated func appendSamples(_ chunk: [Float]) {
        bufferLock.lock()
        samples.append(contentsOf: chunk)
        bufferLock.unlock()
    }

    /// Test seam — drive a single pass synchronously from tests.
    func forceTickForTests() async {
        await tick()
    }

    private func snapshotWindow(from start: Int, maxLength: Int) -> (slice: [Float], bufferEnd: Int)? {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        let end = samples.count
        guard end > start else { return nil }
        let clampStart = max(start, end - maxLength)
        return (Array(samples[clampStart..<end]), end)
    }

    private func tick() async {
        guard !disabled else {
            Log.pipeline.debug("streaming tick: skipped (disabled)")
            return
        }
        guard inFlight == nil else {
            Log.pipeline.debug("streaming tick: skipped (inFlight)")
            return
        }

        guard let snap = snapshotWindow(
            from: committedSampleOffset,
            maxLength: mode.windowSamples
        ) else {
            Log.pipeline.debug("streaming tick: no slice (committedOffset=\(self.committedSampleOffset, privacy: .public) bufferEmpty)")
            return
        }
        let slice = snap.slice
        Log.pipeline.debug("streaming tick: slice samples=\(slice.count, privacy: .public) (~\(String(format: "%.2f", Double(slice.count) / 16_000), privacy: .public)s) bufferEnd=\(snap.bufferEnd, privacy: .public) committedOffset=\(self.committedSampleOffset, privacy: .public)")

        let trans = transcription
        let passMode = self.mode
        let task: Task<Void, Never> = Task.detached(priority: .userInitiated) { [weak self] in
            let timed: TimedTranscript
            do {
                timed = try await trans.transcribeTimed(samples: slice, sampleRate: 16_000)
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    Log.pipeline.error("streaming whisper failed: \(String(describing: error), privacy: .public) — disabling further passes")
                    self.disabled = true
                    self.onPartialUpdate?(self.committedText, "")
                }
                return
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                let cutoffCs = Int64(passMode.commitAdvanceSeconds * 100)
                let (head, tail) = timed.split(atCentiseconds: cutoffCs)
                let lastT1: Int64 = head.segments.last?.t1Centiseconds ?? -1
                Log.pipeline.debug("streaming tick: split cutoffCs=\(cutoffCs, privacy: .public) head.segs=\(head.segments.count, privacy: .public) head.text.len=\(head.text.count, privacy: .public) head.lastT1=\(lastT1, privacy: .public) tail.segs=\(tail.segments.count, privacy: .public) tail.text.len=\(tail.text.count, privacy: .public)")
                if !head.text.isEmpty {
                    self.committedText += head.text
                    self.committedSampleOffset += passMode.commitAdvanceSamples
                    Log.pipeline.debug("streaming tick: COMMIT advance=\(passMode.commitAdvanceSamples, privacy: .public) committedTextLen=\(self.committedText.count, privacy: .public) newCommittedOffset=\(self.committedSampleOffset, privacy: .public)")
                } else {
                    Log.pipeline.debug("streaming tick: NO COMMIT (head empty) — committedOffset frozen at \(self.committedSampleOffset, privacy: .public)")
                }
                self.onPartialUpdate?(self.committedText, tail.text)
            }
        }
        inFlight = task
        _ = await task.value
        inFlight = nil
    }
}
