import XCTest
@testable import SayMoore

final class TimedTranscriptTests: XCTestCase {
    func testInitAggregatesText() {
        let t = TimedTranscript(segments: [
            TimedSegment(text: "Hello", t0Centiseconds: 0,   t1Centiseconds: 50),
            TimedSegment(text: " world.", t0Centiseconds: 60, t1Centiseconds: 120),
        ])
        XCTAssertEqual(t.text, "Hello world.")
    }
    func testEmptySegmentsYieldsEmptyText() {
        XCTAssertEqual(TimedTranscript(segments: []).text, "")
    }
    func testSplitAtCentiseconds() {
        let t = TimedTranscript(segments: [
            TimedSegment(text: "alpha", t0Centiseconds: 0,   t1Centiseconds: 100),
            TimedSegment(text: " bravo", t0Centiseconds: 110, t1Centiseconds: 200),
            TimedSegment(text: " charlie", t0Centiseconds: 210, t1Centiseconds: 320),
        ])
        let (head, tail) = t.split(atCentiseconds: 205)
        XCTAssertEqual(head.text, "alpha bravo")
        XCTAssertEqual(tail.text, " charlie")
    }
    func testSplitBeforeAnySegmentLeavesAllInTail() {
        let t = TimedTranscript(segments: [
            TimedSegment(text: "x", t0Centiseconds: 100, t1Centiseconds: 200),
        ])
        let (head, tail) = t.split(atCentiseconds: 50)
        XCTAssertTrue(head.segments.isEmpty)
        XCTAssertEqual(tail.text, "x")
    }
    func testSplitAfterAllSegmentsLeavesAllInHead() {
        let t = TimedTranscript(segments: [
            TimedSegment(text: "x", t0Centiseconds: 0, t1Centiseconds: 100),
        ])
        let (head, tail) = t.split(atCentiseconds: 5000)
        XCTAssertEqual(head.text, "x")
        XCTAssertTrue(tail.segments.isEmpty)
    }
}
