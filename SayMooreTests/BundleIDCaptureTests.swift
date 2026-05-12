import XCTest
@testable import SayMoore

final class BundleIDCaptureTests: XCTestCase {
    private final class FakeWorkspace: WorkspaceProvider, @unchecked Sendable {
        var bundle: String?
        var frontmostBundleID: String? { bundle }
    }

    func testReturnsCurrentWhenNonSelf() {
        let ws = FakeWorkspace()
        ws.bundle = "com.apple.TextEdit"
        let cap = BundleIDCapturer(provider: ws, ownBundleID: "com.seemoretmoore.saymoore")
        XCTAssertEqual(cap.capture(), "com.apple.TextEdit")
    }

    func testFallsBackToLastNonSelfWhenCurrentIsSelf() {
        let ws = FakeWorkspace()
        let cap = BundleIDCapturer(provider: ws, ownBundleID: "com.seemoretmoore.saymoore")

        ws.bundle = "com.apple.TextEdit"
        XCTAssertEqual(cap.capture(), "com.apple.TextEdit")

        ws.bundle = "com.seemoretmoore.saymoore" // collision
        XCTAssertEqual(cap.capture(), "com.apple.TextEdit") // falls back
    }

    func testReturnsNilWhenNoFrontmostAndNoHistory() {
        let ws = FakeWorkspace()
        ws.bundle = nil
        let cap = BundleIDCapturer(provider: ws, ownBundleID: "com.seemoretmoore.saymoore")
        XCTAssertNil(cap.capture())
    }

    func testNilBundleDoesNotClobberLastNonSelf() {
        let ws = FakeWorkspace()
        let cap = BundleIDCapturer(provider: ws, ownBundleID: "com.seemoretmoore.saymoore")

        ws.bundle = "com.apple.TextEdit"
        XCTAssertEqual(cap.capture(), "com.apple.TextEdit")

        ws.bundle = nil
        XCTAssertEqual(cap.capture(), "com.apple.TextEdit")
    }

    func testUpdatesLastNonSelfAcrossCaptures() {
        let ws = FakeWorkspace()
        let cap = BundleIDCapturer(provider: ws, ownBundleID: "com.seemoretmoore.saymoore")

        ws.bundle = "com.apple.TextEdit"
        _ = cap.capture()
        ws.bundle = "com.tinyspeck.slackmacgap"
        XCTAssertEqual(cap.capture(), "com.tinyspeck.slackmacgap")

        ws.bundle = "com.seemoretmoore.saymoore"
        XCTAssertEqual(cap.capture(), "com.tinyspeck.slackmacgap")
    }
}
