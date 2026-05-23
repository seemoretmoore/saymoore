import XCTest
@testable import SayMoore

final class ActiveDisplayResolverTests: XCTestCase {
    /// Primary at (0,0) 1440×900, secondary to the right at (1440,0) 1920×1080.
    /// CGWindow Y is flipped: y=0 in CG coords == top of primary == NSScreen y=900.
    private let primary = ActiveDisplayResolver.ScreenFrame(
        frame: NSRect(x: 0, y: 0, width: 1440, height: 900)
    )
    private let secondary = ActiveDisplayResolver.ScreenFrame(
        frame: NSRect(x: 1440, y: 0, width: 1920, height: 1080)
    )

    func testPickWindowFrameFlipsCGCoordsToNS() {
        // Primary 1440×900 at origin. CG window at (100, 80, 400, 300)
        // → CG bottom edge y = 80 + 300 = 380 → NS y = 900 - 380 = 520.
        let infos: [[String: Any]] = [[
            kCGWindowOwnerPID as String: pid_t(42),
            kCGWindowBounds as String: [
                "X": CGFloat(100), "Y": CGFloat(80),
                "Width": CGFloat(400), "Height": CGFloat(300),
            ],
        ]]
        let frame = ActiveDisplayResolver.pickWindowFrame(
            frontmostPID: 42,
            windowInfos: infos,
            primaryFrame: primary.frame
        )
        XCTAssertEqual(frame, NSRect(x: 100, y: 520, width: 400, height: 300))
    }

    func testPickWindowFrameReturnsNilWhenNoPID() {
        let frame = ActiveDisplayResolver.pickWindowFrame(
            frontmostPID: nil,
            windowInfos: [],
            primaryFrame: primary.frame
        )
        XCTAssertNil(frame)
    }

    func testPickWindowFrameReturnsNilWhenNoOwnedWindow() {
        let infos: [[String: Any]] = [[
            kCGWindowOwnerPID as String: pid_t(99),
            kCGWindowBounds as String: [
                "X": CGFloat(0), "Y": CGFloat(0),
                "Width": CGFloat(100), "Height": CGFloat(100),
            ],
        ]]
        let frame = ActiveDisplayResolver.pickWindowFrame(
            frontmostPID: 42,
            windowInfos: infos,
            primaryFrame: primary.frame
        )
        XCTAssertNil(frame)
    }

    func testPicksScreenContainingWindowMidpoint_Primary() {
        // Window at CG (100, 100, 200, 200) → midpoint CG (200, 200) → NSScreen y = 900 - 200 = 700.
        // NSPoint (200, 700) is inside primary's NSRect (0..1440, 0..900).
        let infos: [[String: Any]] = [[
            kCGWindowOwnerPID as String: pid_t(42),
            kCGWindowBounds as String: [
                "X": CGFloat(100), "Y": CGFloat(100),
                "Width": CGFloat(200), "Height": CGFloat(200),
            ],
        ]]
        let pick = ActiveDisplayResolver.pickScreen(
            frontmostPID: 42, windowInfos: infos, screens: [primary, secondary]
        )
        XCTAssertEqual(pick?.frame, primary.frame)
    }

    func testPicksScreenContainingWindowMidpoint_Secondary() {
        // Window at CG (1800, 200, 400, 300) → midpoint CG (2000, 350) → NSScreen y = 900 - 350 = 550.
        // NSPoint (2000, 550) is inside secondary's NSRect (1440..3360, 0..1080).
        let infos: [[String: Any]] = [[
            kCGWindowOwnerPID as String: pid_t(42),
            kCGWindowBounds as String: [
                "X": CGFloat(1800), "Y": CGFloat(200),
                "Width": CGFloat(400), "Height": CGFloat(300),
            ],
        ]]
        let pick = ActiveDisplayResolver.pickScreen(
            frontmostPID: 42, windowInfos: infos, screens: [primary, secondary]
        )
        XCTAssertEqual(pick?.frame, secondary.frame)
    }

    func testFiltersByFrontmostPID() {
        let infos: [[String: Any]] = [
            [
                kCGWindowOwnerPID as String: pid_t(99),  // other app's window on secondary
                kCGWindowBounds as String: [
                    "X": CGFloat(1800), "Y": CGFloat(200),
                    "Width": CGFloat(400), "Height": CGFloat(300),
                ],
            ],
            [
                kCGWindowOwnerPID as String: pid_t(42),  // our app on primary
                kCGWindowBounds as String: [
                    "X": CGFloat(100), "Y": CGFloat(100),
                    "Width": CGFloat(200), "Height": CGFloat(200),
                ],
            ],
        ]
        let pick = ActiveDisplayResolver.pickScreen(
            frontmostPID: 42, windowInfos: infos, screens: [primary, secondary]
        )
        XCTAssertEqual(pick?.frame, primary.frame)
    }

    func testReturnsNilWhenNoFrontmostPID() {
        let pick = ActiveDisplayResolver.pickScreen(
            frontmostPID: nil, windowInfos: [], screens: [primary]
        )
        XCTAssertNil(pick)
    }

    func testReturnsNilWhenNoWindowOwnedByFrontmost() {
        let infos: [[String: Any]] = [[
            kCGWindowOwnerPID as String: pid_t(99),
            kCGWindowBounds as String: [
                "X": CGFloat(0), "Y": CGFloat(0),
                "Width": CGFloat(10), "Height": CGFloat(10),
            ],
        ]]
        let pick = ActiveDisplayResolver.pickScreen(
            frontmostPID: 42, windowInfos: infos, screens: [primary]
        )
        XCTAssertNil(pick)
    }
}
