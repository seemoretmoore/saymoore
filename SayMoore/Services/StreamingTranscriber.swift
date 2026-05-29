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

    private func snapshotWindow(from start: Int, maxLength: Int) -> (slice: [Float], windowStart: Int, bufferEnd: Int)? {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        let end = samples.count
        guard end > start else { return nil }
        let clampStart = max(start, end - maxLength)
        return (Array(samples[clampStart..<end]), clampStart, end)
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
        let windowStart = snap.windowStart
        Log.pipeline.debug("streaming tick: slice samples=\(slice.count, privacy: .public) (~\(String(format: "%.2f", Double(slice.count) / 16_000), privacy: .public)s) windowStart=\(windowStart, privacy: .public) bufferEnd=\(snap.bufferEnd, privacy: .public) committedOffset=\(self.committedSampleOffset, privacy: .public)")

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
                // Eager commit: the pill is rolling dictation feedback, not the
                // authoritative output (that's the separate final full-buffer
                // transcribe), so favour always-flowing text over per-word
                // revision. Commit the whole slice and slide to where its speech
                // ended. Crucially this commits a single long continuous segment
                // (fluent speech → one segment spanning the slice) instead of
                // stalling: the old slice-relative cutoff dropped any segment
                // ending past 5s into an uncommittable tail, so committedText
                // froze and the pill went near-empty.
                if let lastSeg = timed.segments.last {
                    self.committedText += timed.text
                    // centiseconds → 16 kHz samples (×160 = ×16_000/100). Anchor
                    // the advance to the window we actually read (windowStart,
                    // clamped when behind) so we never re-read (duplication) and
                    // never overshoot un-transcribed audio (dropped words).
                    let committedEnd = windowStart + Int(lastSeg.t1Centiseconds) * 160
                    // Never go backwards (degenerate t1) — guarantee progress.
                    self.committedSampleOffset = max(committedEnd, self.committedSampleOffset + 1)
                    Log.pipeline.debug("streaming tick: COMMIT len=\(self.committedText.count, privacy: .public) windowStart=\(windowStart, privacy: .public) lastT1=\(lastSeg.t1Centiseconds, privacy: .public)cs → offset=\(self.committedSampleOffset, privacy: .public)")
                } else {
                    // No segments (pure silence/noise): no content boundary to
                    // anchor to — slide by the fallback stride so the window
                    // keeps moving and the HUD can't freeze (9218f0f).
                    self.committedSampleOffset = windowStart + passMode.commitAdvanceSamples
                    Log.pipeline.debug("streaming tick: NO SEGMENTS slide windowStart=\(windowStart, privacy: .public) + \(passMode.commitAdvanceSamples, privacy: .public) → offset=\(self.committedSampleOffset, privacy: .public)")
                }
                // No revisable tail under eager commit — the pill shows the
                // rolling tail of committedText (head-truncated by the HUD).
                self.onPartialUpdate?(self.committedText, "")
            }
        }
        inFlight = task
        _ = await task.value
        inFlight = nil
    }
}
