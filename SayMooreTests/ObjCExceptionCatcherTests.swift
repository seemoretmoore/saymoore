import XCTest
@testable import SayMoore

/// The AirPods crash fix depends on `ObjCExceptionCatcher` turning an
/// otherwise-uncatchable Objective-C `NSException` (raised by `installTap` on an
/// aggregate device) into a Swift-catchable error, so the recorder's existing
/// error path runs instead of the process aborting.
final class ObjCExceptionCatcherTests: XCTestCase {
    func test_normalBlock_doesNotThrow() throws {
        var ran = false
        try ObjCExceptionCatcher.catchException { ran = true }
        XCTAssertTrue(ran)
    }

    func test_raisedNSException_isConvertedToSwiftError() {
        XCTAssertThrowsError(
            try ObjCExceptionCatcher.catchException {
                NSException(name: .invalidArgumentException,
                            reason: "format mismatch",
                            userInfo: nil).raise()
            }
        ) { error in
            let ns = error as NSError
            XCTAssertEqual(ns.domain, "SayMoore.ObjCException")
            XCTAssertEqual(ns.localizedDescription, "format mismatch")
        }
    }
}
