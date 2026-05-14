import XCTest
@testable import SayMoore

final class ErrorsTests: XCTestCase {
    func testPayloadFreeCasesEqualThemselves() {
        XCTAssertEqual(SayMooreError.micPermissionDenied, .micPermissionDenied)
        XCTAssertEqual(SayMooreError.transcriptionGarbage, .transcriptionGarbage)
        XCTAssertEqual(SayMooreError.cleanupTimedOut, .cleanupTimedOut)
        XCTAssertEqual(SayMooreError.ollamaUnreachable, .ollamaUnreachable)
        XCTAssertEqual(SayMooreError.ollamaModelNotPulled, .ollamaModelNotPulled)
        XCTAssertEqual(SayMooreError.pasteClipboardContended, .pasteClipboardContended)
        XCTAssertEqual(SayMooreError.pasteInjectionFailed, .pasteInjectionFailed)
        XCTAssertEqual(SayMooreError.modelMissing, .modelMissing)
        XCTAssertEqual(SayMooreError.modelCorrupted, .modelCorrupted)
        XCTAssertEqual(SayMooreError.diskFull, .diskFull)
        XCTAssertEqual(SayMooreError.watchdogTimeout, .watchdogTimeout)
        XCTAssertEqual(SayMooreError.recordingTooLong, .recordingTooLong)
        XCTAssertEqual(SayMooreError.silentCapture, .silentCapture)
    }

    func testDifferentDiscriminantsAreNotEqual() {
        XCTAssertNotEqual(SayMooreError.micPermissionDenied, .cleanupTimedOut)
        XCTAssertNotEqual(SayMooreError.recordingTooLong, .silentCapture)
        XCTAssertNotEqual(SayMooreError.modelMissing, .modelCorrupted)
    }

    func testPayloadBearingCasesDistinguishPayloads() {
        let e1 = NSError(domain: "X", code: 1)
        let e2 = NSError(domain: "X", code: 2)
        let e1b = NSError(domain: "X", code: 1)

        XCTAssertEqual(SayMooreError.audioEngineFailed(underlying: e1),
                       .audioEngineFailed(underlying: e1b))
        XCTAssertNotEqual(SayMooreError.audioEngineFailed(underlying: e1),
                          .audioEngineFailed(underlying: e2))

        XCTAssertEqual(SayMooreError.transcriptionFailed(underlying: e1),
                       .transcriptionFailed(underlying: e1b))
        XCTAssertNotEqual(SayMooreError.transcriptionFailed(underlying: e1),
                          .transcriptionFailed(underlying: e2))

        XCTAssertEqual(SayMooreError.cleanupFailed(underlying: e1),
                       .cleanupFailed(underlying: e1b))
        XCTAssertNotEqual(SayMooreError.cleanupFailed(underlying: e1),
                          .cleanupFailed(underlying: e2))
    }

    func testPasteFocusChangedComparesBothFields() {
        XCTAssertEqual(SayMooreError.pasteFocusChanged(captured: "a", current: "b"),
                       .pasteFocusChanged(captured: "a", current: "b"))
        XCTAssertNotEqual(SayMooreError.pasteFocusChanged(captured: "a", current: "b"),
                          .pasteFocusChanged(captured: "a", current: "c"))
        XCTAssertNotEqual(SayMooreError.pasteFocusChanged(captured: nil, current: nil),
                          .pasteFocusChanged(captured: "x", current: nil))
    }

    func testPermissionRevokedMidSessionComparesPermission() {
        XCTAssertEqual(SayMooreError.permissionRevokedMidSession(.microphone),
                       .permissionRevokedMidSession(.microphone))
        XCTAssertNotEqual(SayMooreError.permissionRevokedMidSession(.microphone),
                          .permissionRevokedMidSession(.accessibility))
    }
}
