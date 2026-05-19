import AppKit
import XCTest
@testable import SayMoore

@MainActor
final class RecordingHUDControllerTests: XCTestCase {
    func testExpandedLabelIncludesPresetName() {
        XCTAssertEqual(
            RecordingHUDController.expandedLabel(preset: "Slack"),
            "Recording — Slack"
        )
    }

    func testCollapsedLabelDropsPresetName() {
        XCTAssertEqual(RecordingHUDController.collapsedLabel, "Recording")
    }

    func testTopCenterFrameSitsBelowMenuBar() throws {
        // Synthetic 1440×900 screen with menu bar reducing visibleFrame to y=0..875.
        // top-center frame at width=280 height=44 → x = 720 - 140 = 580, y = 875 - 40 - 44 = 791.
        // We can't easily fake NSScreen.visibleFrame so just verify the math via a real screen
        // if available, or skip on headless runners.
        guard let screen = NSScreen.screens.first else {
            throw XCTSkip("no NSScreen available")
        }
        let frame = RecordingHUDController.topCenterFrame(in: screen, size: NSSize(width: 280, height: 44))
        XCTAssertEqual(frame.size, NSSize(width: 280, height: 44))
        XCTAssertEqual(frame.midX, screen.visibleFrame.midX, accuracy: 0.5)
        XCTAssertEqual(frame.maxY, screen.visibleFrame.maxY - 40, accuracy: 0.5)
    }

    func testShowSetsExpandedLabelThenCollapseSwitches() {
        let hud = RecordingHUDController()
        hud.show(preset: "Slack")
        XCTAssertEqual(hud.currentLabelText, "Recording — Slack")
        hud.collapseLabel()
        XCTAssertEqual(hud.currentLabelText, "Recording")
        hud.hide()
    }
}
