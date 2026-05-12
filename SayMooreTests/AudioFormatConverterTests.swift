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
        // Allow ±2 frames of resampler slack.
        XCTAssertEqual(Int(out.frameLength), 16_000, accuracy: 2)

        let outPtr = out.floatChannelData![0]
        // Skip the first/last few frames where the resampler ramps; midpoint should be ~0.5.
        XCTAssertEqual(outPtr[8_000], 0.5, accuracy: 0.05)
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
