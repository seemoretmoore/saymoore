import XCTest
@testable import SayMoore

@MainActor
final class AudioFeedbackServiceTests: XCTestCase {

    // MARK: - Helpers

    /// Returns (service, startCallCount, stopCallCount) using closures for injection.
    private func makeService(muted: Bool = false) -> (AudioFeedbackService, Counter, Counter) {
        let startCount = Counter()
        let stopCount  = Counter()
        let svc = AudioFeedbackService(
            muted: muted,
            playStart: { startCount.increment() },
            playStop:  { stopCount.increment()  }
        )
        return (svc, startCount, stopCount)
    }

    // MARK: - Tests

    func testStartChimeFires_idleToRecording() {
        let (svc, startCount, stopCount) = makeService()
        svc.handle(old: .idle, new: .recording)
        XCTAssertEqual(startCount.value, 1, "start chime must fire on .idle → .recording")
        XCTAssertEqual(stopCount.value,  0, "stop chime must not fire on .idle → .recording")
    }

    func testStopChimeFires_recordingToTranscribing() {
        let (svc, startCount, stopCount) = makeService()
        svc.handle(old: .recording, new: .transcribing)
        XCTAssertEqual(stopCount.value,  1, "stop chime must fire on .recording → .transcribing")
        XCTAssertEqual(startCount.value, 0, "start chime must not fire on .recording → .transcribing")
    }

    func testMutedServicePlaysNothing() {
        let (svc, startCount, stopCount) = makeService(muted: true)
        svc.handle(old: .idle,      new: .recording)
        svc.handle(old: .recording, new: .transcribing)
        XCTAssertEqual(startCount.value, 0, "muted service must not play start chime")
        XCTAssertEqual(stopCount.value,  0, "muted service must not play stop chime")
    }

    func testNonRelevantTransition_playsNothing() {
        let (svc, startCount, stopCount) = makeService()
        svc.handle(old: .transcribing, new: .cleaning)
        XCTAssertEqual(startCount.value, 0)
        XCTAssertEqual(stopCount.value,  0)
    }
}

// MARK: - Counter helper (reference type so closures can mutate it)

private final class Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
