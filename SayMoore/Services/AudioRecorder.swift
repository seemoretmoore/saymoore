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

    func start() throws {
        guard !isRecording else { return }
        _ = ringBuffer.drainAll()

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
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            guard let converted = try? conv.convert(buffer) else { return }
            guard let ch = converted.floatChannelData?[0] else { return }
            let frames = Int(converted.frameLength)
            let bp = UnsafeBufferPointer(start: ch, count: frames)
            _ = ring.write(bp)
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
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false

        let samples = ringBuffer.drainAll()
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
}
