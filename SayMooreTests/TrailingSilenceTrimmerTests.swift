import XCTest
@testable import SayMoore

final class TrailingSilenceTrimmerTests: XCTestCase {

    private let frame = SileroFrameSamples // 512 samples = 32ms @ 16kHz

    /// Build a buffer of `frameCount` full frames, value 0.01 (placeholder PCM).
    private func buffer(frames frameCount: Int) -> [Float] {
        Array(repeating: Float(0.01), count: frameCount * frame)
    }

    func testTrimsTrailingSilencePastHangover() {
        // 50 speech frames then 50 silence frames. Last speech ends at 50*512.
        // Trailing silence = 50 frames (1.6s) ≥ floor, so trim to
        // lastSpeechEnd + 300ms hangover (4800 samples).
        let canned: [VADFrameClass] =
            Array(repeating: .speech, count: 50) + Array(repeating: .silence, count: 50)
        let backend = FakeVADBackend(canned: canned)
        let trimmer = TrailingSilenceTrimmer(backend: backend)

        let result = trimmer.trim(buffer(frames: 100))

        XCTAssertEqual(result.count, 50 * frame + 4800,
                       "should keep through last speech frame + 300ms hangover")
    }

    func testNoSpeechReturnsUnchanged() {
        let backend = FakeVADBackend(canned: Array(repeating: .silence, count: 20))
        let trimmer = TrailingSilenceTrimmer(backend: backend)
        let input = buffer(frames: 20)

        let result = trimmer.trim(input)

        XCTAssertEqual(result.count, input.count, "no speech → never trim (could be quiet speech VAD missed)")
    }

    func testTrailingSilenceBelowFloorReturnsUnchanged() {
        // 50 speech + 5 silence frames. 5*512 = 2560 samples = 160ms < 400ms floor.
        let canned: [VADFrameClass] =
            Array(repeating: .speech, count: 50) + Array(repeating: .silence, count: 5)
        let backend = FakeVADBackend(canned: canned)
        let trimmer = TrailingSilenceTrimmer(backend: backend)
        let input = buffer(frames: 55)

        let result = trimmer.trim(input)

        XCTAssertEqual(result.count, input.count, "trailing silence under floor → leave clean endings alone")
    }

    func testSpeechToEndReturnsUnchanged() {
        let backend = FakeVADBackend(canned: Array(repeating: .speech, count: 40))
        let trimmer = TrailingSilenceTrimmer(backend: backend)
        let input = buffer(frames: 40)

        let result = trimmer.trim(input)

        XCTAssertEqual(result.count, input.count, "no trailing silence → unchanged")
    }

    func testResetsBackendSoRepeatedTrimsAreDeterministic() {
        // FakeVADBackend loops + tracks a cursor; trim() must reset it so a second
        // call classifies from the start of the canned sequence, not mid-cursor.
        let canned: [VADFrameClass] =
            Array(repeating: .speech, count: 50) + Array(repeating: .silence, count: 50)
        let backend = FakeVADBackend(canned: canned)
        let trimmer = TrailingSilenceTrimmer(backend: backend)
        let input = buffer(frames: 100)

        let first = trimmer.trim(input)
        let second = trimmer.trim(input)

        XCTAssertEqual(first.count, second.count, "repeated trims on identical input must match (backend reset each run)")
    }
}
