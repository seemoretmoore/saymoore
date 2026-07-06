import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import os

/// Lazily builds the 16 kHz converter from the first tap buffer's real format,
/// then hands the same instance to every subsequent callback. `@unchecked
/// Sendable` (guarded by an internal lock) so it can be captured into the
/// audio-thread tap block, which strict concurrency treats as `@Sendable`.
private final class LazyConverterStore: @unchecked Sendable {
    private let lock = NSLock()
    private let targetSampleRate: Double
    private var converter: AudioFormatConverter?

    init(targetSampleRate: Double) {
        self.targetSampleRate = targetSampleRate
    }

    func converter(for buffer: AVAudioPCMBuffer) throws -> AudioFormatConverter {
        lock.lock()
        defer { lock.unlock() }
        if let converter { return converter }
        let created = try AudioFormatConverter(
            inputFormat: buffer.format,
            targetSampleRate: targetSampleRate
        )
        converter = created
        return created
    }
}

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

    /// UserDefaults key for the pinned input-device UID. Absent/empty ⇒ follow
    /// the macOS system-default input.
    nonisolated static let inputDeviceUIDKey = "input.device.uid"

    private let deviceEnumerator: AudioInputDeviceEnumerating
    private let pinnedDeviceUIDProvider: @Sendable () -> String?

    init(
        deviceEnumerator: AudioInputDeviceEnumerating = CoreAudioInputDeviceEnumerator(),
        pinnedDeviceUIDProvider: @escaping @Sendable () -> String? = {
            UserDefaults.standard.string(forKey: AudioRecorder.inputDeviceUIDKey)
        }
    ) {
        self.deviceEnumerator = deviceEnumerator
        self.pinnedDeviceUIDProvider = pinnedDeviceUIDProvider
    }

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
        pinInputDeviceIfNeeded()
        let inputFormat = resolveInputFormat()
        // DIAG (AirPods reroute investigation): capture the node's output vs input
        // formats before tapping. On an AirPods aggregate device these disagree and
        // installTap raises an *Objective-C* NSException ("format mismatch") that
        // Swift's do/catch can't see — the failure is then invisible. These logs
        // pinpoint the exact formats + the last checkpoint reached on the next test.
        let hwInputFormat = input.inputFormat(forBus: 0)
        Log.audio.info("start DIAG: tapFmt(out0)=\(inputFormat.sampleRate, privacy: .public)Hz/\(inputFormat.channelCount, privacy: .public)ch  nodeIn(in0)=\(hwInputFormat.sampleRate, privacy: .public)Hz/\(hwInputFormat.channelCount, privacy: .public)ch")
        guard inputFormat.sampleRate > 0 else {
            Log.audio.error("AudioRecorder start failed: input format 0Hz (ch=\(inputFormat.channelCount, privacy: .public))")
            throw SayMooreError.audioEngineFailed(underlying: RecorderError.invalidInputFormat)
        }
        Log.audio.info("start DIAG: installing tap+converter…")
        try installTapAndConverter()
        Log.audio.info("start DIAG: tap installed OK — starting engine…")

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            Log.audio.error("start DIAG: engine.start() threw (Swift-catchable): \(String(describing: error), privacy: .public)")
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

    /// Test seam: resolve the pinned UID (if any) to a live AudioDeviceID via
    /// the enumerator. Returns nil when nothing is pinned or the pinned device
    /// is absent (e.g. unplugged), which callers treat as "use system default".
    func resolvePinnedDeviceID() -> AudioDeviceID? {
        guard let uid = pinnedDeviceUIDProvider(), !uid.isEmpty else { return nil }
        return deviceEnumerator.deviceID(forUID: uid)
    }

    /// Pin the input AudioUnit (AUHAL) to the resolved device before the engine
    /// starts. On any failure — missing UID, unplugged device, OSStatus error —
    /// log and leave the engine on the system default rather than aborting.
    private func pinInputDeviceIfNeeded() {
        guard let deviceID = resolvePinnedDeviceID() else { return }
        guard let unit = engine.inputNode.audioUnit else {
            Log.audio.error("pin: inputNode.audioUnit unavailable — using system default")
            return
        }
        var dev = deviceID
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &dev,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            Log.audio.error("pin: AudioUnitSetProperty(CurrentDevice=\(deviceID, privacy: .public)) failed OSStatus=\(status, privacy: .public) — using system default")
        } else {
            Log.audio.info("pinned input device id=\(deviceID, privacy: .public)")
        }
    }

    /// Install the tap and build the converter lazily from the first delivered
    /// buffer's format. Shared by `start()` and `restartEngineOnDeviceChange()`
    /// so the capture closure can't drift between the two paths.
    ///
    /// The tap is installed with `format: nil`, so AVAudioEngine uses the input
    /// node's own negotiated format. Passing an explicit format here is what
    /// raised an *uncatchable* Objective-C NSException on AirPods aggregate
    /// devices whose input vs output formats disagree ("format mismatch") — that
    /// exception is invisible to Swift `do/catch` and, unwinding through the
    /// CGEvent-tap C callback, aborted the process (the "hotkey does nothing when
    /// AirPods active" symptom). `nil` removes the format we could mismatch, and
    /// the `installTap` call is additionally wrapped in an ObjC exception guard so
    /// any residual NSException degrades to a Swift throw instead of a crash.
    ///
    /// The converter is bound to its input format, so it is created from the real
    /// delivered `buffer.format` (a re-route can change rate/channels) rather than
    /// a pre-read format that may be stale on a settling Bluetooth route.
    private func installTapAndConverter() throws {
        let ring = self.ringBuffer
        let vad = self.vadService
        let levelHandler = self.onLevelUpdate
        let samplesHandler = self.onSamples
        let errorLock = self.errorLogLock
        // Built once on the first buffer (from its live format), then reused.
        // The store is @unchecked Sendable and lock-serialized so it can be
        // captured into the audio-thread tap block under strict concurrency.
        let converterStore = LazyConverterStore(targetSampleRate: Self.targetSampleRate)

        let tapBlock: AVAudioNodeTapBlock = { buffer, _ in
            do {
                let conv = try converterStore.converter(for: buffer)
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
                let shouldLog = errorLock.withLock { last -> Bool in
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

        Log.audio.info("start DIAG: calling installTap(format=nil, node-negotiated)…")
        do {
            try ObjCExceptionCatcher.catchException {
                self.engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil, block: tapBlock)
            }
        } catch {
            Log.audio.error("AudioRecorder installTap raised ObjC exception: \(error, privacy: .public)")
            throw SayMooreError.audioEngineFailed(underlying: RecorderError.invalidInputFormat)
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
            try installTapAndConverter()
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
