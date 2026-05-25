import XCTest
@testable import SayMoore

final class StreamingModeTests: XCTestCase {
    func testBalancedDefaultParameters() {
        let m = StreamingMode.balanced
        XCTAssertEqual(m.intervalSeconds, 1.5, accuracy: 0.001)
        XCTAssertEqual(m.windowSamples, 16_000 * 10)
        XCTAssertEqual(m.commitAdvanceSamples, 16_000 * 5)
    }
    func testResponsiveParameters() {
        let m = StreamingMode.responsive
        XCTAssertEqual(m.intervalSeconds, 0.75, accuracy: 0.001)
        XCTAssertEqual(m.windowSamples, 16_000 * 8)
        XCTAssertEqual(m.commitAdvanceSamples, 16_000 * 4)
    }
    func testOffHasNoInferenceWork() {
        let m = StreamingMode.off
        XCTAssertEqual(m.intervalSeconds, 0)
        XCTAssertEqual(m.windowSamples, 0)
        XCTAssertEqual(m.commitAdvanceSamples, 0)
    }
    func testRawValueRoundTripsViaUserDefaultsKey() {
        for m in [StreamingMode.off, .balanced, .responsive] {
            XCTAssertEqual(StreamingMode(rawValue: m.rawValue), m)
        }
    }
    func testDefaultIsBalanced() {
        XCTAssertEqual(StreamingMode.default, .balanced)
    }
}
