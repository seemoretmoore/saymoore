import XCTest
@testable import SayMoore

@MainActor
final class AudioFeedbackServiceTests: XCTestCase {

    // MARK: - Helpers

    /// Returns (service, startCount, stopCount, cancelCount, busyCount) using closures for injection.
    private func makeService(muted: Bool = false) -> (AudioFeedbackService, Counter, Counter, Counter, Counter) {
        let startCount  = Counter()
        let stopCount   = Counter()
        let cancelCount = Counter()
        let busyCount   = Counter()
        let svc = AudioFeedbackService(
            muted: muted,
            playStart:  { startCount.increment()  },
            playStop:   { stopCount.increment()   },
            playCancel: { cancelCount.increment() },
            playBusy:   { busyCount.increment()   }
        )
        return (svc, startCount, stopCount, cancelCount, busyCount)
    }

    // MARK: - Tests

    func testStartChimeFires_idleToRecording() {
        let (svc, startCount, stopCount, cancelCount, busyCount) = makeService()
        svc.handle(old: .idle, new: .recording)
        XCTAssertEqual(startCount.value,  1)
        XCTAssertEqual(stopCount.value,   0)
        XCTAssertEqual(cancelCount.value, 0)
        XCTAssertEqual(busyCount.value,   0)
    }

    func testStopChimeFires_recordingToTranscribing() {
        let (svc, startCount, stopCount, cancelCount, _) = makeService()
        svc.handle(old: .recording, new: .transcribing)
        XCTAssertEqual(stopCount.value,   1, "natural stop → .transcribing must fire stop chime")
        XCTAssertEqual(startCount.value,  0)
        XCTAssertEqual(cancelCount.value, 0, "natural stop must not fire cancel chime")
    }

    func testCancelChimeFires_recordingToIdle() {
        let (svc, startCount, stopCount, cancelCount, _) = makeService()
        svc.handle(old: .recording, new: .idle)
        XCTAssertEqual(cancelCount.value, 1, "Esc cancel routes .recording → .idle → cancel chime")
        XCTAssertEqual(stopCount.value,   0, "cancel must not fire stop chime")
        XCTAssertEqual(startCount.value,  0)
    }

    func testStopChimeFires_recordingToError() {
        let (svc, _, stopCount, cancelCount, _) = makeService()
        svc.handle(old: .recording, new: .error(.recordingTooLong))
        XCTAssertEqual(stopCount.value,   1, "error exit from recording falls through to stop chime")
        XCTAssertEqual(cancelCount.value, 0)
    }

    func testBusyChimeFires() {
        let (svc, _, _, _, busyCount) = makeService()
        svc.busy()
        XCTAssertEqual(busyCount.value, 1)
    }

    func testMutedServicePlaysNothing() {
        let (svc, startCount, stopCount, cancelCount, busyCount) = makeService(muted: true)
        svc.handle(old: .idle,      new: .recording)
        svc.handle(old: .recording, new: .transcribing)
        svc.handle(old: .recording, new: .idle)
        svc.busy()
        XCTAssertEqual(startCount.value,  0)
        XCTAssertEqual(stopCount.value,   0)
        XCTAssertEqual(cancelCount.value, 0)
        XCTAssertEqual(busyCount.value,   0)
    }

    func testNonRelevantTransition_playsNothing() {
        let (svc, startCount, stopCount, cancelCount, _) = makeService()
        svc.handle(old: .transcribing, new: .cleaning)
        XCTAssertEqual(startCount.value,  0)
        XCTAssertEqual(stopCount.value,   0)
        XCTAssertEqual(cancelCount.value, 0)
    }
}

// MARK: - Counter helper (reference type so closures can mutate it)

private final class Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
