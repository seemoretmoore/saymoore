import XCTest
@testable import SayMoore

@MainActor
final class AudioRecorderChimeTrimTests: XCTestCase {

    func testTrimDropsLeadingChimeWindow() {
        let sr = AudioRecorder.targetSampleRate
        let trimCount = Int((sr * AudioRecorder.chimeBleedTrimSeconds).rounded())
        let totalCount = trimCount + 1000
        var input = [Float](repeating: 0.5, count: trimCount)  // chime
        input.append(contentsOf: [Float](repeating: 0.9, count: 1000))  // speech

        let out = AudioRecorder.trimChimeBleed(input, sampleRate: sr)

        XCTAssertEqual(out.count, totalCount - trimCount)
        XCTAssertEqual(out.first, 0.9, "leading samples after trim should be the post-chime content")
    }

    func testTrimReturnsEmptyWhenCaptureShorterThanWindow() {
        let sr = AudioRecorder.targetSampleRate
        let trimCount = Int((sr * AudioRecorder.chimeBleedTrimSeconds).rounded())
        let input = [Float](repeating: 0.5, count: trimCount - 10)

        let out = AudioRecorder.trimChimeBleed(input, sampleRate: sr)

        XCTAssertTrue(out.isEmpty, "sub-window capture should trim to empty (caller treats as silentCapture)")
    }

    func testTrimReturnsEmptyOnExactBoundary() {
        let sr = AudioRecorder.targetSampleRate
        let trimCount = Int((sr * AudioRecorder.chimeBleedTrimSeconds).rounded())
        let input = [Float](repeating: 0.5, count: trimCount)

        let out = AudioRecorder.trimChimeBleed(input, sampleRate: sr)

        XCTAssertTrue(out.isEmpty)
    }

    func testTrimEmptyInput() {
        XCTAssertTrue(AudioRecorder.trimChimeBleed([], sampleRate: AudioRecorder.targetSampleRate).isEmpty)
    }
}
