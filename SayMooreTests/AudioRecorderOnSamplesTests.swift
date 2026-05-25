import XCTest
@testable import SayMoore

final class AudioRecorderOnSamplesTests: XCTestCase {
    @MainActor
    func testOnSamplesPropertyIsSettableAndReadable() {
        let r = AudioRecorder()
        let exp = expectation(description: "callback assigned")
        r.onSamples = { samples in
            XCTAssertEqual(samples, [1, 2, 3])
            exp.fulfill()
        }
        // Drive the callback directly — the audio-thread path is exercised by
        // higher-level integration tests; here we just confirm wiring.
        r.onSamples?([1, 2, 3])
        wait(for: [exp], timeout: 0.5)
    }
    @MainActor
    func testOnSamplesNilByDefault() {
        let r = AudioRecorder()
        XCTAssertNil(r.onSamples)
    }
}
