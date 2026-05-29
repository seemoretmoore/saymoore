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

    func testCommitsSingleLongSegmentInsteadOfStalling() async throws {
        // Regression for the near-empty live preview: continuous speech yields
        // one segment spanning the whole slice. Under the old slice-relative
        // 500cs cutoff a single segment ending at t1=700cs fell entirely into
        // the (uncommittable) tail, so committedText never grew. Eager commit
        // must commit it. There is no revisable tail any more → active == "".
        let fake = makeFake(TimedTranscript(segments: [
            TimedSegment(text: "later", t0Centiseconds: 0, t1Centiseconds: 700),
        ]))
        let s = StreamingTranscriber(transcription: fake, mode: .balanced)
        var latest: (String, String) = ("", "")
        s.onPartialUpdate = { c, a in latest = (c, a) }
        s.start()
        s.appendSamples(Array(repeating: Float(0.01), count: 16_000 * 11))
        await s.forceTickForTests()
        XCTAssertEqual(latest.0, "later", "a single long segment must commit, not stall in a tail")
        XCTAssertEqual(latest.1, "", "no revisable tail under eager commit")
        await s.stop()
    }

    func testCommitsAllSegmentsEagerly() async throws {
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
        XCTAssertEqual(latest.0, "alpha beta", "eager commit takes the whole slice, both segments")
        XCTAssertEqual(latest.1, "", "no revisable tail under eager commit")
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

    func testNoSegmentsSlidesByFallbackStride() async {
        // When a pass returns NO segments (pure silence/noise) there's no
        // content boundary to anchor to. committedText must not grow, but the
        // window MUST still slide by the fallback stride so the next tick reads
        // fresh audio instead of re-feeding the same window (freeze, 9218f0f).
        // Asserted via the fake's lastTimedSliceCount shrinkage.
        let fake = FakeTranscriptionService()
        fake.nextTimedResult = .success(TimedTranscript(segments: []))
        let s = StreamingTranscriber(transcription: fake, mode: .balanced)
        var lastCommitted = "sentinel"
        s.onPartialUpdate = { c, _ in lastCommitted = c }
        s.start()
        // Buffer 8s of audio — under the 10s window so the clamp doesn't mask
        // the offset advance.
        s.appendSamples(Array(repeating: Float(0.01), count: 16_000 * 8))
        await s.forceTickForTests()
        let firstSlice = fake.lastTimedSliceCount
        XCTAssertEqual(lastCommitted, "", "no segments → nothing committed")
        await s.forceTickForTests()
        let secondSlice = fake.lastTimedSliceCount
        XCTAssertEqual(
            firstSlice - secondSlice,
            StreamingMode.balanced.commitAdvanceSamples,
            "second tick must see a window shorter by commitAdvanceSamples — proof the offset advanced by the fallback stride with no segments"
        )
        await s.stop()
    }

    func testClampedWindowDoesNotReReadSameAudio() async {
        // Regression for the "very wrong" boundary-misalignment duplication.
        // Buffer 20s — far past the 10s window — so snapshotWindow clamps the
        // window start to end-windowSamples, AHEAD of committedSampleOffset.
        // Bug: the offset advanced by a fixed commitAdvanceSamples from its OLD
        // value, lagging the clamp, so the next tick re-read (and re-committed)
        // the identical audio region. The offset must instead track the clamped
        // window start. We observe the window start via the fake's
        // lastTimedSliceFirstSample with a ramp signal (sample[i] = i).
        let fake = makeFake(TimedTranscript(segments: [
            TimedSegment(text: "x", t0Centiseconds: 0, t1Centiseconds: 100),
        ]))
        let s = StreamingTranscriber(transcription: fake, mode: .balanced)
        s.onPartialUpdate = { _, _ in }
        s.start()
        let total = 16_000 * 20 // 20s; window is 10s → clamp engages
        s.appendSamples((0..<total).map { Float($0) })
        await s.forceTickForTests()
        let firstStart = fake.lastTimedSliceFirstSample
        await s.forceTickForTests()
        let secondStart = fake.lastTimedSliceFirstSample
        XCTAssertGreaterThan(
            secondStart, firstStart,
            "clamped window must advance — re-reading the same start re-commits the same audio (duplication)"
        )
        await s.stop()
    }

    func testAdvanceTracksCommittedContentNotFixedStride() async {
        // The live preview must advance by the audio it actually committed
        // (head.lastT1), NOT a blind commitAdvanceSamples (5s). With the fixed
        // 5s stride, after a short ~1.5s first slice the offset jumps to 5s and
        // the audio in between is never sent to a preview window — the preview
        // drops words and lags. Ramp signal (sample[i] = i) so the fake's
        // lastTimedSliceFirstSample reveals the absolute window start.
        let fake = makeFake(TimedTranscript(segments: [
            TimedSegment(text: "hello world", t0Centiseconds: 0, t1Centiseconds: 150),
        ]))
        let s = StreamingTranscriber(transcription: fake, mode: .balanced)
        s.onPartialUpdate = { _, _ in }
        s.start()
        // 3s ramp — under the 10s window so no clamp masks the advance.
        s.appendSamples((0..<(16_000 * 3)).map { Float($0) })
        await s.forceTickForTests()
        let firstStart = fake.lastTimedSliceFirstSample
        await s.forceTickForTests()
        let secondStart = fake.lastTimedSliceFirstSample
        XCTAssertEqual(firstStart, 0, "first window starts at 0")
        XCTAssertEqual(
            secondStart, Float(150 * 160),
            "second window must resume at the committed-content boundary (150cs → 24000 samples), not a blind 5s stride"
        )
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
