import XCTest
@testable import SayMoore

@MainActor
final class StreamingTranscriberTests: XCTestCase {

    func makeFake(_ result: TimedTranscript) -> FakeTranscriptionService {
        let f = FakeTranscriptionService()
        f.nextTimedResult = .success(result)
        return f
    }

    func testEmitsPartialAfterFirstPass() async throws {
        // Single segment with t1=100cs (1s) is well below the 500cs (5s) commit
        // cutoff for .balanced, so per spec it COMMITS on the first pass.
        let fake = makeFake(TimedTranscript(segments: [
            TimedSegment(text: "hello", t0Centiseconds: 0, t1Centiseconds: 100),
        ]))
        let s = StreamingTranscriber(transcription: fake, mode: .balanced)
        let exp = expectation(description: "partial emitted")
        s.onPartialUpdate = { committed, active in
            XCTAssertEqual(committed, "hello")
            XCTAssertEqual(active, "")
            exp.fulfill()
        }
        s.start()
        s.appendSamples(Array(repeating: Float(0.01), count: 16_000 * 11))
        await s.forceTickForTests()
        await fulfillment(of: [exp], timeout: 1.0)
        await s.stop()
    }

    func testSegmentPastCommitCutoffStaysInActive() async throws {
        // Segment ends at t1=700cs, well past 500cs commit cutoff for .balanced.
        // Must stay in active tail, not be lost.
        let fake = makeFake(TimedTranscript(segments: [
            TimedSegment(text: "later", t0Centiseconds: 600, t1Centiseconds: 700),
        ]))
        let s = StreamingTranscriber(transcription: fake, mode: .balanced)
        var latest: (String, String) = ("", "")
        s.onPartialUpdate = { c, a in latest = (c, a) }
        s.start()
        s.appendSamples(Array(repeating: Float(0.01), count: 16_000 * 11))
        await s.forceTickForTests()
        XCTAssertEqual(latest.0, "")
        XCTAssertEqual(latest.1, "later")
        await s.stop()
    }

    func testCommitsSegmentsOlderThanCommitAdvance() async throws {
        let fake = makeFake(TimedTranscript(segments: [
            TimedSegment(text: "alpha", t0Centiseconds: 0,   t1Centiseconds: 400),
            TimedSegment(text: " beta", t0Centiseconds: 410, t1Centiseconds: 900),
        ]))
        let s = StreamingTranscriber(transcription: fake, mode: .balanced)
        var latest: (String, String) = ("", "")
        s.onPartialUpdate = { c, a in latest = (c, a) }
        s.start()
        s.appendSamples(Array(repeating: Float(0.01), count: 16_000 * 11))
        await s.forceTickForTests()
        XCTAssertEqual(latest.0, "alpha", "first segment should be committed (t1=4s ≤ 5s)")
        XCTAssertEqual(latest.1, " beta", "second segment is still in active tail")
        await s.stop()
    }

    func testCommittedTextAccumulatesAcrossPasses() async throws {
        let fake = FakeTranscriptionService()
        let s = StreamingTranscriber(transcription: fake, mode: .balanced)
        var latest: (String, String) = ("", "")
        s.onPartialUpdate = { c, a in latest = (c, a) }
        s.start()

        fake.nextTimedResult = .success(TimedTranscript(segments: [
            TimedSegment(text: "alpha", t0Centiseconds: 0, t1Centiseconds: 400),
        ]))
        s.appendSamples(Array(repeating: Float(0.01), count: 16_000 * 11))
        await s.forceTickForTests()
        XCTAssertEqual(latest.0, "alpha")
        XCTAssertEqual(latest.1, "")

        fake.nextTimedResult = .success(TimedTranscript(segments: [
            TimedSegment(text: " beta", t0Centiseconds: 0, t1Centiseconds: 400),
        ]))
        s.appendSamples(Array(repeating: Float(0.01), count: 16_000 * 6))
        await s.forceTickForTests()
        XCTAssertEqual(latest.0, "alpha beta", "second pass should append to committed prefix")
        await s.stop()
    }

    func testStopIsIdempotent() async {
        let s = StreamingTranscriber(transcription: FakeTranscriptionService(), mode: .balanced)
        s.start()
        await s.stop()
        await s.stop()
    }

    func testInferenceErrorEmitsClearingPartialAndDisablesFurtherPasses() async {
        let fake = FakeTranscriptionService()
        fake.nextTimedResult = .failure(SayMooreError.modelMissing)
        let s = StreamingTranscriber(transcription: fake, mode: .balanced)
        var emits: [(String, String)] = []
        s.onPartialUpdate = { c, a in emits.append((c, a)) }
        s.start()
        s.appendSamples(Array(repeating: Float(0.01), count: 16_000 * 11))
        await s.forceTickForTests()
        XCTAssertEqual(emits.count, 1, "errored pass must emit one clearing partial so the HUD drops the italic tail")
        XCTAssertEqual(emits.first?.0, "", "committed text was empty pre-error")
        XCTAssertEqual(emits.first?.1, "", "active tail must be cleared on error")
        await s.forceTickForTests()
        XCTAssertEqual(emits.count, 1, "no further emits after disable")
        await s.stop()
    }

    func testOffModeIsNeverInstantiated() {
        XCTAssertEqual(StreamingMode.off.intervalSeconds, 0)
    }
}
