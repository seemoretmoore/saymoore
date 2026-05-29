import Foundation

/// Trims trailing silence/noise from a finished recording buffer before the
/// final whisper pass. Whisper (large-v3-turbo) tends to emit spurious filler
/// tokens ("okay", "my date") when the audio ends in several hundred ms of
/// near-silence + room tone; cutting that tail removes the conditions that
/// produce the hallucination.
///
/// Runs the existing Silero `VADBackend` offline over the buffer to find the
/// last speech frame, then keeps a short hangover past it so genuine quiet
/// trailing words survive. Conservative by design: if no speech is found, or
/// the trailing silence is shorter than `minTrailingSilence`, the buffer is
/// returned untouched.
///
/// Use a backend dedicated to trimming — NOT the live `VADService` instance —
/// because Silero carries LSTM state across frames; `trim` resets the backend
/// before each run so a prior recording can't leak in.
final class TrailingSilenceTrimmer {
    private let backend: VADBackend
    private let frameSamples: Int
    private let hangoverSamples: Int
    private let minTrailingSilenceSamples: Int

    /// - Parameters:
    ///   - backend: dedicated VAD backend (e.g. a fresh `SileroVADBackend`).
    ///   - sampleRate: PCM sample rate; matches `VADService.sampleRate` (16 kHz).
    ///   - hangover: audio kept past the last speech frame (default 300 ms).
    ///   - minTrailingSilence: only trim when trailing silence is at least this
    ///     long (default 400 ms) — leaves clean endings alone.
    init(
        backend: VADBackend,
        sampleRate: Int = VADService.sampleRate,
        hangover: TimeInterval = 0.3,
        minTrailingSilence: TimeInterval = 0.4
    ) {
        self.backend = backend
        self.frameSamples = SileroFrameSamples
        self.hangoverSamples = Int(hangover * Double(sampleRate))
        self.minTrailingSilenceSamples = Int(minTrailingSilence * Double(sampleRate))
    }

    /// Returns `samples` with trailing silence dropped, or unchanged if there's
    /// nothing safe to trim.
    func trim(_ samples: [Float]) -> [Float] {
        guard samples.count >= frameSamples else { return samples }

        backend.reset()

        // Silero is causal/stateful — classify full frames from the start and
        // remember where the last speech frame ended (in absolute samples).
        var lastSpeechEnd = -1
        var offset = 0
        while offset + frameSamples <= samples.count {
            let frame = Array(samples[offset ..< offset + frameSamples])
            let cls: VADFrameClass
            do {
                cls = try backend.classify(frame)
            } catch {
                // A bad frame shouldn't nuke the recording — bail out unchanged.
                Log.vad.error("trailing-silence trim classify failed: \(String(describing: error), privacy: .public)")
                return samples
            }
            if cls == .speech {
                lastSpeechEnd = offset + frameSamples
            }
            offset += frameSamples
        }

        // No speech detected → don't trim (could be quiet speech VAD missed).
        guard lastSpeechEnd >= 0 else { return samples }

        let trailingSilence = samples.count - lastSpeechEnd
        guard trailingSilence >= minTrailingSilenceSamples else { return samples }

        let keep = min(samples.count, lastSpeechEnd + hangoverSamples)
        guard keep < samples.count else { return samples }
        return Array(samples[0 ..< keep])
    }
}
