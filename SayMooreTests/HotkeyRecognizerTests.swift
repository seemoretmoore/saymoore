import XCTest
@testable import SayMoore

final class HotkeyRecognizerTests: XCTestCase {
    func testIdleEmitsNothing() {
        var r = HotkeyRecognizer()
        XCTAssertEqual(r.process(.ctrlUp(at: 0)), .none)
        XCTAssertEqual(r.process(.otherKey(at: 0)), .none)
    }

    func testCleanDoubleTapEmitsToggle() {
        var r = HotkeyRecognizer()
        XCTAssertEqual(r.process(.ctrlDown(at: 0.000)), .none)
        XCTAssertEqual(r.process(.ctrlUp(at:   0.080)), .none)
        XCTAssertEqual(r.process(.ctrlDown(at: 0.180)), .toggle)
    }

    func testReturnsToIdleAfterToggle() {
        var r = HotkeyRecognizer()
        _ = r.process(.ctrlDown(at: 0.000))
        _ = r.process(.ctrlUp(at:   0.080))
        XCTAssertEqual(r.process(.ctrlDown(at: 0.180)), .toggle)
        // Stray ctrlUp after the recognized toggle is ignored.
        XCTAssertEqual(r.process(.ctrlUp(at: 0.200)), .none)
    }

    func testInterveningKeyDuringHoldCancels() {
        var r = HotkeyRecognizer()
        _ = r.process(.ctrlDown(at: 0.000))
        XCTAssertEqual(r.process(.otherKey(at: 0.020)), .none) // cancels
        // Sequence reset — releasing ctrl now should not arm second-tap window.
        _ = r.process(.ctrlUp(at: 0.030))
        XCTAssertEqual(r.process(.ctrlDown(at: 0.100)), .none)
    }

    func testInterveningKeyBetweenTapsCancels() {
        var r = HotkeyRecognizer()
        _ = r.process(.ctrlDown(at: 0.000))
        _ = r.process(.ctrlUp(at:   0.080))
        XCTAssertEqual(r.process(.otherKey(at: 0.100)), .none) // cancels armed state
        XCTAssertEqual(r.process(.ctrlDown(at: 0.150)), .none) // not a toggle anymore
    }

    func testGapTooLongRestartsButDoesNotEmit() {
        var r = HotkeyRecognizer()
        _ = r.process(.ctrlDown(at: 0.000))
        _ = r.process(.ctrlUp(at:   0.080))
        XCTAssertEqual(r.process(.ctrlDown(at: 0.500)), .none) // 420ms gap > 300ms
        // But the late ctrlDown should now be treated as a new first tap.
        _ = r.process(.ctrlUp(at: 0.560))
        XCTAssertEqual(r.process(.ctrlDown(at: 0.700)), .toggle)
    }

    func testCtrlHeldWithoutReleaseDoesNotEmit() {
        var r = HotkeyRecognizer()
        XCTAssertEqual(r.process(.ctrlDown(at: 0.000)), .none)
        XCTAssertEqual(r.process(.ctrlDown(at: 0.500)), .none) // repeat / synthetic re-down, still held
        XCTAssertEqual(r.process(.ctrlDown(at: 1.000)), .none)
    }

    func testCtrlAThenCtrlERejected() {
        // PRD acceptance case: Ctrl-A then Ctrl-E (intervening A/E keys cancel sequence).
        var r = HotkeyRecognizer()
        _ = r.process(.ctrlDown(at: 0.000))
        XCTAssertEqual(r.process(.otherKey(at: 0.010)), .none) // 'a' down
        _ = r.process(.ctrlUp(at: 0.080))
        _ = r.process(.ctrlDown(at: 0.150))
        XCTAssertEqual(r.process(.otherKey(at: 0.160)), .none) // 'e' down
        XCTAssertEqual(r.process(.ctrlUp(at: 0.200)), .none)
    }

    func testThreeQuickTapsEmitsExactlyOneToggle() {
        var r = HotkeyRecognizer()
        _ = r.process(.ctrlDown(at: 0.000))
        _ = r.process(.ctrlUp(at:   0.060))
        XCTAssertEqual(r.process(.ctrlDown(at: 0.120)), .toggle) // first → idle
        _ = r.process(.ctrlUp(at: 0.180))
        XCTAssertEqual(r.process(.ctrlDown(at: 0.240)), .none) // begins a new pair
    }

    func testBoundaryExactlyAt300ms() {
        var r = HotkeyRecognizer()
        _ = r.process(.ctrlDown(at: 0.000))
        _ = r.process(.ctrlUp(at:   0.000))
        XCTAssertEqual(r.process(.ctrlDown(at: 0.300)), .toggle) // ≤300ms inclusive
    }
}
