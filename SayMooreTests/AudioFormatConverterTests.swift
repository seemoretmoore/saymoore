import XCTest
import AVFoundation
@testable import SayMoore

final class AudioFormatConverterTests: XCTestCase {
    func testConvertsStereo48kFloat32ToMono16kFloat32() throws {
        let input = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        )!
        let conv = try AudioFormatConverter(inputFormat: input, targetSampleRate: 16_000)

        // 1 second of audio: a constant value per channel so we can sanity-check the output.
        let frames: AVAudioFrameCount = 48_000
        let buf = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: frames)!
        buf.frameLength = frames
        let l = buf.floatChannelData![0]
        let r = buf.floatChannelData![1]
        for i in 0..<Int(frames) {
            l[i] = 0.5
            r[i] = 0.5
        }

        let out = try conv.convert(buf)
        XCTAssertEqual(out.format.sampleRate, 16_000)
        XCTAssertEqual(out.format.channelCount, 1)
        XCTAssertEqual(out.format.commonFormat, .pcmFormatFloat32)
        // Streaming-mode .noDataNow drops resampler-latency frames at the tail
        // (~6% on a one-shot buffer). Acceptable: in production this converter
        // is fed continuously and only the very last tap buffer loses its tail.
        XCTAssertGreaterThan(Int(out.frameLength), 14_900)
        XCTAssertLessThanOrEqual(Int(out.frameLength), 16_002)

        let outPtr = out.floatChannelData![0]
        // Skip the first/last few frames where the resampler ramps; midpoint should be ~0.5.
        XCTAssertEqual(outPtr[8_000], 0.5, accuracy: 0.05)
    }

    func testStreamingManyBuffersDoesNotFinalize() throws {
        // Regression: previously the converter signaled .endOfStream after each
        // tap buffer, finalizing the resampler so all subsequent buffers produced
        // 0 frames (observed in production as 1600-sample recordings regardless
        // of duration). Verify cumulative output ≈ input × (16000/48000) across
        // many sequential convert() calls on a single instance.
        let input = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        )!
        let conv = try AudioFormatConverter(inputFormat: input, targetSampleRate: 16_000)

        let bufferFrames: AVAudioFrameCount = 1024
        let bufferCount = 50  // ~1.07s of 48k audio in 21ms chunks
        var totalOut = 0
        for _ in 0..<bufferCount {
            let buf = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: bufferFrames)!
            buf.frameLength = bufferFrames
            for i in 0..<Int(bufferFrames) {
                buf.floatChannelData![0][i] = 0.25
                buf.floatChannelData![1][i] = 0.25
            }
            let out = try conv.convert(buf)
            totalOut += Int(out.frameLength)
        }
        let expected = Int(Double(bufferFrames) * Double(bufferCount) * (16_000.0 / 48_000.0))
        // Allow generous slack for resampler ramp-up across buffer seams.
        XCTAssertGreaterThan(totalOut, expected - 200)
        XCTAssertLessThan(totalOut, expected + 200)
    }

    func testPassThroughWhenAlreadyTargetFormat() throws {
        let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let conv = try AudioFormatConverter(inputFormat: target, targetSampleRate: 16_000)

        let frames: AVAudioFrameCount = 1600
        let buf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: frames)!
        buf.frameLength = frames
        for i in 0..<Int(frames) {
            buf.floatChannelData![0][i] = Float(i) / Float(frames)
        }

        let out = try conv.convert(buf)
        XCTAssertEqual(out.format.sampleRate, 16_000)
        XCTAssertEqual(out.format.channelCount, 1)
        XCTAssertEqual(Int(out.frameLength), 1600, accuracy: 2)
    }
}
