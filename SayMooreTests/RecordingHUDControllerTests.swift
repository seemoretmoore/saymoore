import AppKit
import XCTest
@testable import SayMoore

@MainActor
final class RecordingHUDControllerTests: XCTestCase {
    func testTopCenterFrameSitsBelowMenuBar() throws {
        guard let screen = NSScreen.screens.first else {
            throw XCTSkip("no NSScreen available")
        }
        let frame = RecordingHUDController.topCenterFrame(in: screen, size: NSSize(width: 130, height: 30))
        XCTAssertEqual(frame.size, NSSize(width: 130, height: 30))
        XCTAssertEqual(frame.midX, screen.visibleFrame.midX, accuracy: 0.5)
        XCTAssertEqual(frame.maxY, screen.visibleFrame.maxY - 40, accuracy: 0.5)
    }

    func testBottomCenterFrameHangsBelowWindowWithTopJustInside() {
        // Window at NS coords (100, 200, 800, 600). Pill 130×30.
        // Expect: midX = 500; pill top (maxY) = 200 + 4 = 204; pill bottom (minY) = 174.
        let windowFrame = NSRect(x: 100, y: 200, width: 800, height: 600)
        let pill = RecordingHUDController.bottomCenterFrame(
            in: windowFrame,
            size: NSSize(width: 130, height: 30)
        )
        XCTAssertEqual(pill.midX, windowFrame.midX, accuracy: 0.001)
        XCTAssertEqual(pill.maxY, windowFrame.minY + 4, accuracy: 0.001)
        XCTAssertEqual(pill.minY, windowFrame.minY + 4 - 30, accuracy: 0.001)
        XCTAssertEqual(pill.size, NSSize(width: 130, height: 30))
    }

    func testUpdateLevelShiftsAndSmoothes() {
        let hud = RecordingHUDController()
        XCTAssertEqual(hud.displayLevels, Array(repeating: 0, count: 12))

        hud.updateLevel(1.0)
        // levelBuffer = [0×11, 1]; displayBuffer[i] = 0.4*0 + 0.6*level[i]
        XCTAssertEqual(hud.displayLevels[11], 0.6, accuracy: 0.001)
        XCTAssertEqual(hud.displayLevels[10], 0.0, accuracy: 0.001)

        hud.updateLevel(1.0)
        // levelBuffer = [0×10, 1, 1]
        // displayBuffer[11] = 0.4*0.6 + 0.6*1 = 0.84
        // displayBuffer[10] = 0.4*0   + 0.6*1 = 0.6
        XCTAssertEqual(hud.displayLevels[11], 0.84, accuracy: 0.001)
        XCTAssertEqual(hud.displayLevels[10], 0.6, accuracy: 0.001)
        XCTAssertEqual(hud.displayLevels[0], 0.0, accuracy: 0.001)
    }

    func testUpdateLevelClampsOutOfRange() {
        let hud = RecordingHUDController()
        hud.updateLevel(2.5)  // clamps to 1
        XCTAssertEqual(hud.displayLevels[11], 0.6, accuracy: 0.001)
        hud.updateLevel(-0.5) // clamps to 0
        // displayBuffer[11] = 0.4*0.6 + 0.6*0 = 0.24
        // displayBuffer[10] = 0.4*0 + 0.6*1 = 0.6  (the 1 shifted into [10])
        XCTAssertEqual(hud.displayLevels[11], 0.24, accuracy: 0.001)
        XCTAssertEqual(hud.displayLevels[10], 0.6, accuracy: 0.001)
    }

    func testHideResetsBars() {
        let hud = RecordingHUDController()
        hud.updateLevel(1.0)
        hud.updateLevel(1.0)
        XCTAssertGreaterThan(hud.displayLevels[11], 0.5)
        hud.hide()
        XCTAssertEqual(hud.displayLevels, Array(repeating: 0, count: 12))
    }
}
