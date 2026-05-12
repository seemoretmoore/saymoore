import XCTest
@testable import SayMoore

final class ScaffoldTests: XCTestCase {
    @MainActor
    func testAppStateStartsIdle() {
        let state = AppState()
        XCTAssertEqual(state.state, .idle)
    }

    @MainActor
    func testAppStateTransitions() {
        let state = AppState()
        state.transition(to: .recording)
        XCTAssertEqual(state.state, .recording)
        state.transition(to: .idle)
        XCTAssertEqual(state.state, .idle)
    }

    func testErrorEquality() {
        XCTAssertEqual(SayMooreError.transcriptionGarbage, SayMooreError.transcriptionGarbage)
        XCTAssertNotEqual(SayMooreError.transcriptionGarbage, SayMooreError.cleanupTimedOut)
        XCTAssertEqual(
            SayMooreError.pasteFocusChanged(captured: "a", current: "b"),
            SayMooreError.pasteFocusChanged(captured: "a", current: "b")
        )
    }
}
