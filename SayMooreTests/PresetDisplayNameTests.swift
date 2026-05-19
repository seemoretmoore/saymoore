import XCTest
@testable import SayMoore

final class PresetDisplayNameTests: XCTestCase {
    func testKnownBundleIDsMapToFriendlyNames() {
        XCTAssertEqual(PresetDisplayName.resolve(bundleID: "com.tinyspeck.slackmacgap"), "Slack")
        XCTAssertEqual(PresetDisplayName.resolve(bundleID: "com.barebones.bbedit"), "BBEdit")
        XCTAssertEqual(PresetDisplayName.resolve(bundleID: "com.apple.Notes"), "Notes")
        XCTAssertEqual(PresetDisplayName.resolve(bundleID: "com.apple.MobileSMS"), "Messages")
    }

    func testUnknownBundleIDFallsBackToTitleCasedLastSegment() {
        XCTAssertEqual(PresetDisplayName.resolve(bundleID: "com.example.foo"), "Foo")
        XCTAssertEqual(PresetDisplayName.resolve(bundleID: "com.apple.Safari"), "Safari")
    }

    func testNilBundleIDResolvesToDefault() {
        XCTAssertEqual(PresetDisplayName.resolve(bundleID: nil), "default")
    }

    func testEmptyBundleIDResolvesToDefault() {
        XCTAssertEqual(PresetDisplayName.resolve(bundleID: ""), "default")
    }

    func testSingleSegmentBundleIDIsTitleCased() {
        XCTAssertEqual(PresetDisplayName.resolve(bundleID: "noDots"), "NoDots")
    }

    func testTrailingDotResolvesToDefault() {
        // Last split segment is empty string; should not crash, falls back to default.
        XCTAssertEqual(PresetDisplayName.resolve(bundleID: "com.example."), "Example")
    }
}
