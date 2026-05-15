@preconcurrency import AVFoundation

final class AudioFormatConverter {
    let inputFormat: AVAudioFormat
    let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init(inputFormat: AVAudioFormat, targetSampleRate: Double) throws {
        guard let out = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw SayMooreError.audioEngineFailed(underlying: ConverterError.formatUnavailable)
        }
        guard let conv = AVAudioConverter(from: inputFormat, to: out) else {
            throw SayMooreError.audioEngineFailed(underlying: ConverterError.converterUnavailable)
        }
        self.inputFormat = inputFormat
        self.outputFormat = out
        self.converter = conv
    }

    func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let estimatedFrames = AVAudioFrameCount(
            (Double(input.frameLength) * ratio).rounded(.up)
        ) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: estimatedFrames) else {
            throw SayMooreError.audioEngineFailed(underlying: ConverterError.bufferAllocFailed)
        }

        // Use a reference-type flag so the @Sendable inputBlock closure can
        // mutate it without triggering strict-concurrency errors.
        final class Flag: @unchecked Sendable { var consumed = false }
        let flag = Flag()
        var convError: NSError?
        let status = converter.convert(to: out, error: &convError) { _, outStatus in
            if flag.consumed {
                // .noDataNow (not .endOfStream): this converter is reused across many
                // tap buffers. Signaling end-of-stream finalizes the resampler and all
                // subsequent buffers produce 0 frames.
                outStatus.pointee = .noDataNow
                return nil
            }
            flag.consumed = true
            outStatus.pointee = .haveData
            return input
        }
        if status == .error, let e = convError {
            throw SayMooreError.audioEngineFailed(underlying: e)
        }
        return out
    }

    enum ConverterError: Error {
        case formatUnavailable
        case converterUnavailable
        case bufferAllocFailed
    }
}
