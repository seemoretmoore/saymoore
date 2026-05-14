import AVFoundation
import Foundation

@MainActor
final class AudioRecorder {
    static let targetSampleRate: Double = 16_000
    static let bufferCapacityFrames = 16_000 * 120  // 2 minutes at 16k mono

    private let engine = AVAudioEngine()
    private let ringBuffer = AudioRingBuffer(capacity: bufferCapacityFrames)
    private var converter: AudioFormatConverter?
    private(set) var isRecording = false
    private var lastErrorLogTime: ContinuousClock.Instant?

    func start() throws {
        guard !isRecording else { return }
        ringBuffer.reset()

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
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            do {
                let converted = try conv.convert(buffer)
                guard let ch = converted.floatChannelData?[0] else { return }
                let frames = Int(converted.frameLength)
                let bp = UnsafeBufferPointer(start: ch, count: frames)
                _ = ring.write(bp)
            } catch {
                // Rate-limit converter error logs to 1/sec
                if let last = self?.lastErrorLogTime, ContinuousClock.now - last < .seconds(1) { return }
                self?.lastErrorLogTime = ContinuousClock.now
                Log.audio.error("AudioRecorder converter error: \(error, privacy: .public)")
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

        let samples = ringBuffer.drainAll()

        if ringBuffer.overflowed {
            throw SayMooreError.recordingTooLong
        }
        if samples.isEmpty {
            throw SayMooreError.silentCapture
        }

        Log.audio.info("AudioRecorder stopped (\(samples.count, privacy: .public) samples)")
        return samples
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
