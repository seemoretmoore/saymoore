import AVFoundation
import Foundation
import os

@MainActor
final class AudioRecorder {
    static let targetSampleRate: Double = 16_000
    static let bufferCapacityFrames = 16_000 * 120  // 2 minutes at 16k mono

    // Glass chime ("recording started") plays ~6–12ms AFTER the input tap is
    // installed, so on internal-speaker + internal-mic setups the chime bleeds
    // into capture and whisper transcribes it as "ding". Drop the leading
    // window covering the chime envelope.
    static let chimeBleedTrimSeconds: Double = 0.25

    private let engine = AVAudioEngine()
    private let ringBuffer = AudioRingBuffer(capacity: bufferCapacityFrames)
    private var converter: AudioFormatConverter?
    private(set) var isRecording = false
    // Tap-callback runs on the audio thread; lock-protect the rate-limit timestamp.
    private let errorLogLock = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)

    // Optional VAD service. When set, every converted PCM chunk is forwarded
    // to it from the tap callback. The service buffers + classifies async on
    // its own worker queue. Set this BEFORE start(); reset is handled here.
    var vadService: VADService?

    /// Fired from the audio thread for every converted PCM chunk with a
    /// normalized 0...1 amplitude (RMS → dBFS, clamped to -60…0 dBFS).
    /// Handler is responsible for its own threading; the HUD wiring in
    /// AppDelegate hops to MainActor before touching CALayer.
    var onLevelUpdate: (@Sendable (Float) -> Void)?

    /// Fired from the audio thread for every converted PCM chunk with the
    /// raw 16 kHz mono float samples. Handler is responsible for its own
    /// threading; the StreamingTranscriber subscribes here to feed its
    /// sliding-window buffer without disturbing the ring buffer that the
    /// final `stop() -> [Float]` drain relies on.
    var onSamples: (@Sendable ([Float]) -> Void)?

    /// Fired (on the main actor) when AVAudioEngine posts a
    /// configurationChangeNotification while we're mid-recording. The recorder
    /// has already stopped itself by the time this fires — the handler is
    /// responsible for surfacing the abort to the rest of the pipeline.
    var onDeviceChange: (@MainActor () -> Void)?
    nonisolated(unsafe) private var configChangeObserver: NSObjectProtocol?

    // Re-route bookkeeping. AirPods/Bluetooth route negotiation (e.g. switching
    // the buds into HFP/SCO mic mode the moment we start capturing) fires
    // .AVAudioEngineConfigurationChange — often repeatedly. Instead of aborting,
    // we restart the engine onto the new default input and keep recording. These
    // guards stop the notification storm (including the ones our own restart
    // provokes) from looping forever.
    private var isRerouting = false
    private var rerouteCount = 0
    private var rerouteSettleUntil: ContinuousClock.Instant?
    private static let maxReroutesPerSession = 3
    private static let rerouteSettleWindow: Duration = .milliseconds(500)

    /// Test-only accessor: the AVAudioEngine the recorder observes for
    /// configuration-change notifications. Tests post a notification with this
    /// engine as `object` so the observer (filtered on the same engine) fires.
    var engineForObserverTesting: AVAudioEngine { engine }

    deinit {
        if let obs = configChangeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    func start() throws {
        guard !isRecording else { return }
        ringBuffer.reset()
        vadService?.reset()
        setupConfigChangeObserverIfNeeded()

        let input = engine.inputNode
        let inputFormat = resolveInputFormat()
        guard inputFormat.sampleRate > 0 else {
            Log.audio.error("AudioRecorder start failed: input format 0Hz (ch=\(inputFormat.channelCount, privacy: .public))")
            throw SayMooreError.audioEngineFailed(underlying: RecorderError.invalidInputFormat)
        }
        try installTapAndConverter(inputFormat: inputFormat)

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw SayMooreError.audioEngineFailed(underlying: error)
        }
        rerouteCount = 0
        isRerouting = false
        rerouteSettleUntil = nil
        isRecording = true
        Log.audio.info("AudioRecorder started (input=\(inputFormat.sampleRate, privacy: .public)Hz, ch=\(inputFormat.channelCount, privacy: .public))")
    }

    /// Read the input node's format, warming up a cold Bluetooth/first-access
    /// input that reports 0 Hz until its route is active. Mirrors the documented
    /// "first Ctrl-Ctrl of the day records 0 samples" AVAudioEngine quirk, which
    /// is permanent rather than one-shot when AirPods are the input.
    private func resolveInputFormat() -> AVAudioFormat {
        let input = engine.inputNode
        var fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate <= 0 else { return fmt }
        engine.prepare()
        var attempts = 0
        while fmt.sampleRate <= 0 && attempts < 5 {
            Thread.sleep(forTimeInterval: 0.020)
            fmt = input.outputFormat(forBus: 0)
            attempts += 1
        }
        if fmt.sampleRate > 0 {
            Log.audio.info("AudioRecorder input warmed up to \(fmt.sampleRate, privacy: .public)Hz after \(attempts, privacy: .public) retries")
        } else {
            Log.audio.error("AudioRecorder input still 0Hz after warmup (ch=\(fmt.channelCount, privacy: .public))")
        }
        return fmt
    }

    /// Create the converter for `inputFormat` and install the tap. Shared by
    /// `start()` and `restartEngineOnDeviceChange()` so the capture closure can't
    /// drift between the two paths. The converter is bound to its input format,
    /// so a re-route MUST recreate it for the new device's rate/channels.
    private func installTapAndConverter(inputFormat: AVAudioFormat) throws {
        let conv = try AudioFormatConverter(
            inputFormat: inputFormat,
            targetSampleRate: Self.targetSampleRate
        )
        self.converter = conv

        let ring = self.ringBuffer
        let vad = self.vadService
        let levelHandler = self.onLevelUpdate
        let samplesHandler = self.onSamples
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            do {
                let converted = try conv.convert(buffer)
                guard let ch = converted.floatChannelData?[0] else { return }
                let frames = Int(converted.frameLength)
                let bp = UnsafeBufferPointer(start: ch, count: frames)
                _ = ring.write(bp)
                if let samplesHandler {
                    samplesHandler(Array(bp))
                }
                // Forward to VAD if attached. One small heap alloc per ~22ms
                // tap (typical chunk ~341 samples post-convert at 16kHz).
                // Acceptable for dictation — not hard-real-time audio.
                if let vad {
                    vad.feed(Array(bp))
                }
                if let levelHandler {
                    levelHandler(Self.computeNormalizedLevel(bp))
                }
            } catch {
                // Rate-limit converter error logs to 1/sec across audio-thread invocations.
                guard let self else { return }
                let shouldLog = self.errorLogLock.withLock { last -> Bool in
                    let now = ContinuousClock.now
                    if let last, now - last < .seconds(1) { return false }
                    last = now
                    return true
                }
                if shouldLog {
                    Log.audio.error("AudioRecorder converter error: \(error, privacy: .public)")
                }
            }
        }
    }

    @discardableResult
    func stop() throws -> [Float] {
        guard isRecording else {
            throw SayMooreError.audioEngineFailed(underlying: RecorderError.notRecording)
        }
        // C6: removeTap → stop → 20ms drain-fence → drainAll; prevents in-flight tap callbacks racing drain
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        Thread.sleep(forTimeInterval: 0.020)

        let drained = ringBuffer.drainAll()

        if ringBuffer.overflowed {
            throw SayMooreError.recordingTooLong
        }

        let samples = Self.trimChimeBleed(drained, sampleRate: Self.targetSampleRate)
        if samples.isEmpty {
            throw SayMooreError.silentCapture
        }

        Log.audio.info("AudioRecorder stopped (\(samples.count, privacy: .public) samples, trimmed \(drained.count - samples.count, privacy: .public))")
        return samples
    }

    /// RMS over the buffer → dBFS → normalized 0…1 via a -60…0 dBFS window.
    /// Pure function; safe to call from the audio thread.
    nonisolated static func computeNormalizedLevel(_ samples: UnsafeBufferPointer<Float>) -> Float {
        let n = samples.count
        guard n > 0 else { return 0 }
        var sumSquares: Float = 0
        for i in 0..<n {
            let s = samples[i]
            sumSquares += s * s
        }
        let rms = sqrtf(sumSquares / Float(n))
        let db = 20 * log10f(max(rms, 1e-7))
        return max(0, min(1, (db + 60) / 60))
    }

    /// `[Float]` overload for tests.
    nonisolated static func computeNormalizedLevel(_ samples: [Float]) -> Float {
        samples.withUnsafeBufferPointer { computeNormalizedLevel($0) }
    }

    static func trimChimeBleed(_ samples: [Float], sampleRate: Double) -> [Float] {
        let trimCount = Int((sampleRate * Self.chimeBleedTrimSeconds).rounded())
        guard trimCount > 0, samples.count > trimCount else { return [] }
        return Array(samples.dropFirst(trimCount))
    }

    static func writeWAV(samples: [Float], to url: URL) throws {
        let data = WAVWriter.encode(samples: samples, sampleRate: Int(Self.targetSampleRate))
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: url.path
        )
    }

    func cancel() {
        guard isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        _ = ringBuffer.drainAll()
        Log.audio.info("AudioRecorder cancelled")
    }

    enum RecorderError: Error {
        case invalidInputFormat
        case notRecording
        case deviceChanged
    }

    private func setupConfigChangeObserverIfNeeded() {
        guard configChangeObserver == nil else { return }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRecording, !self.isRerouting else { return }
                self.restartEngineOnDeviceChange()
            }
        }
    }

    /// Mid-recording `.AVAudioEngineConfigurationChange` handler. Instead of
    /// aborting, restart the engine onto the current default input and keep
    /// recording — connecting/removing AirPods, or macOS forcing them into SCO
    /// mic mode at start, no longer kills the session. Falls back to the old
    /// abort only when no usable input remains or the storm exceeds the cap.
    private func restartEngineOnDeviceChange() {
        guard isRecording, !isRerouting else { return }
        // The restart below re-posts configuration changes; the settle window
        // swallows that echo so we don't re-route in a loop.
        if let until = rerouteSettleUntil, ContinuousClock.now < until {
            Log.audio.debug("configurationChange within settle window — ignoring")
            return
        }
        rerouteCount += 1
        if rerouteCount > Self.maxReroutesPerSession {
            Log.audio.error("configurationChange — reroute cap (\(Self.maxReroutesPerSession, privacy: .public)) exceeded, aborting")
            abortRecordingForDeviceChange()
            return
        }

        isRerouting = true
        let oldRate = engine.inputNode.outputFormat(forBus: 0).sampleRate
        // Tear down current tap/engine using stop()'s drain-fence pattern.
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        Thread.sleep(forTimeInterval: 0.020)

        let newFormat = resolveInputFormat()
        guard newFormat.sampleRate > 0 else {
            Log.audio.error("configurationChange — no usable input (0Hz), aborting")
            abortRecordingForDeviceChange()
            return
        }
        do {
            try installTapAndConverter(inputFormat: newFormat)
            try engine.start()
        } catch {
            Log.audio.error("AudioRecorder reroute failed: \(error, privacy: .public) — aborting")
            abortRecordingForDeviceChange()
            return
        }
        rerouteSettleUntil = ContinuousClock.now.advanced(by: Self.rerouteSettleWindow)
        isRerouting = false
        Log.audio.info("AudioRecorder rerouted (\(oldRate, privacy: .public)Hz→\(newFormat.sampleRate, privacy: .public)Hz, ch=\(newFormat.channelCount, privacy: .public), #\(self.rerouteCount, privacy: .public))")
    }

    /// Fallback to the original behavior: stop the recorder and surface the
    /// abort so the pipeline resets to idle. Used when re-routing can't recover.
    private func abortRecordingForDeviceChange() {
        isRerouting = false
        _ = try? stop()
        onDeviceChange?()
    }

    // Test-only: mark as recording without starting the engine.
    // Allows unit tests to exercise stop() paths without AVAudioEngine.
    func _startForTests() {
        isRecording = true
    }
}
