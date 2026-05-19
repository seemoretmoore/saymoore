import XCTest
@testable import SayMoore

@MainActor
final class NotificationCoordinatorTests: XCTestCase {
    final class FakeClock {
        var now: ContinuousClock.Instant
        init() { self.now = ContinuousClock.now }
    }
    final class SpySink: NotificationSink, @unchecked Sendable {
        var calls: [(String, String)] = []
        func send(title: String, body: String) { calls.append((title, body)) }
    }

    func test_firstErrorOfClass_isSent() {
        let sink = SpySink()
        let clock = FakeClock()
        let coord = NotificationCoordinator(sink: sink, cooldown: .seconds(60), now: { clock.now })
        coord.notify(.ollamaUnreachable)
        XCTAssertEqual(sink.calls.count, 1)
    }

    func test_repeatWithinCooldown_isCoalesced() {
        let sink = SpySink()
        let clock = FakeClock()
        let coord = NotificationCoordinator(sink: sink, cooldown: .seconds(60), now: { clock.now })
        coord.notify(.ollamaUnreachable)
        clock.now = clock.now.advanced(by: .seconds(30))
        coord.notify(.ollamaUnreachable)
        XCTAssertEqual(sink.calls.count, 1)
    }

    func test_repeatAfterCooldown_isResent() {
        let sink = SpySink()
        let clock = FakeClock()
        let coord = NotificationCoordinator(sink: sink, cooldown: .seconds(60), now: { clock.now })
        coord.notify(.ollamaUnreachable)
        clock.now = clock.now.advanced(by: .seconds(61))
        coord.notify(.ollamaUnreachable)
        XCTAssertEqual(sink.calls.count, 2)
    }

    func test_differentClasses_areIndependent() {
        let sink = SpySink()
        let clock = FakeClock()
        let coord = NotificationCoordinator(sink: sink, cooldown: .seconds(60), now: { clock.now })
        coord.notify(.ollamaUnreachable)
        coord.notify(.micPermissionDenied)
        XCTAssertEqual(sink.calls.count, 2)
    }

    func test_persistentErrors_setBadge_andTransientErrors_dontTouchIt() {
        let sink = SpySink()
        let clock = FakeClock()
        let coord = NotificationCoordinator(sink: sink, cooldown: .seconds(60), now: { clock.now })
        var observed: NotificationCoordinator.Badge? = .init(key: .ollamaUnreachable, label: "init")
        coord.onBadgeChange = { observed = $0 }
        coord.notify(.ollamaUnreachable)
        XCTAssertEqual(observed?.label, "Ollama down")
        coord.notify(.pasteFocusChanged(captured: nil, current: nil))
        XCTAssertEqual(observed?.label, "Ollama down")
        coord.clearBadge(for: .ollamaUnreachable)
        XCTAssertNil(observed)
    }
}
