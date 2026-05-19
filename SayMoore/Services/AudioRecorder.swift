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

    func start() throws {
        guard !isRecording else { return }
        ringBuffer.reset()
        vadService?.reset()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw SayMooreError.audioEngineFailed(underlying: RecorderError.invalidInputFormat)
        }
        let conv = try AudioFormatConverter(
            inputFormat: inputFormat,
            targetSampleRate: Self.targetSampleRate
        )
        self.converter = conv

        let ring = self.ringBuffer
        let vad = self.vadService
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            do {
                let converted = try conv.convert(buffer)
                guard let ch = converted.floatChannelData?[0] else { return }
                let frames = Int(converted.frameLength)
                let bp = UnsafeBufferPointer(start: ch, count: frames)
                _ = ring.write(bp)
                // Forward to VAD if attached. One small heap alloc per ~22ms
                // tap (typical chunk ~341 samples post-convert at 16kHz).
                // Acceptable for dictation — not hard-real-time audio.
                if let vad {
                    vad.feed(Array(bp))
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

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw SayMooreError.audioEngineFailed(underlying: error)
        }
        isRecording = true
        Log.audio.info("AudioRecorder started (input=\(inputFormat.sampleRate, privacy: .public)Hz, ch=\(inputFormat.channelCount, privacy: .public))")
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
    }

    // Test-only: mark as recording without starting the engine.
    // Allows unit tests to exercise stop() paths without AVAudioEngine.
    func _startForTests() {
        isRecording = true
    }
}
