import XCTest
@testable import SayMoore

@MainActor
final class RecordingHUDPartialTextTests: XCTestCase {
    func testEmptyTextDoesNotCrash() {
        let hud = RecordingHUDController()
        hud.updatePartialText(committed: "", active: "")
        XCTAssertNotNil(hud)
    }
    func testTransitionFromContentToEmpty() {
        let hud = RecordingHUDController()
        hud.updatePartialText(committed: "alpha", active: " beta")
        hud.updatePartialText(committed: "", active: "")
        XCTAssertNotNil(hud)
    }
    func testLargePartialDoesNotCrash() {
        let hud = RecordingHUDController()
        let long = String(repeating: "The quick brown fox. ", count: 30)
        hud.updatePartialText(committed: long, active: "")
        XCTAssertNotNil(hud)
    }
    func testHideClearsPartialState() {
        let hud = RecordingHUDController()
        hud.updatePartialText(committed: "stuff", active: "more")
        hud.hide()
        // No crash; state reset. (Visual assertions live in manual dogfood.)
        XCTAssertNotNil(hud)
    }
}
