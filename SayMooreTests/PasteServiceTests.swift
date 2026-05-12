import XCTest
@testable import SayMoore

final class PasteServiceTests: XCTestCase {

    private final class FakePasteboard: PasteboardAdapter, @unchecked Sendable {
        var changeCount: Int = 0
        var current: String? = "previous-clipboard"
        private(set) var ops: [String] = []
        var onSet: (() -> Void)?
        func savedString() -> String? { current }
        func clearContents() { ops.append("clear"); current = nil }
        func setString(_ s: String) {
            ops.append("set:\(s)")
            current = s
            changeCount += 1
            onSet?()
        }
    }

    private final class FakeKeyboard: KeyboardAdapter, @unchecked Sendable {
        var pastes = 0
        var onPostCmdV: (() -> Void)?
        func postCmdV() { pastes += 1; onPostCmdV?() }
    }

    private final class FakeFrontmost: FrontmostAdapter, @unchecked Sendable {
        var bundleID: String?
    }

    // MARK: - Happy path

    func testHappyPathPastesAndRestoresOriginalString() async throws {
        let pb = FakePasteboard()
        pb.current = "old"
        pb.changeCount = 5
        let kb = FakeKeyboard()
        let fm = FakeFrontmost(); fm.bundleID = "com.apple.TextEdit"

        let svc = PasteService(
            pasteboard: pb, keyboard: kb, frontmost: fm,
            restoreDelay: .zero
        )
        try await svc.paste(transcript: "hello world", capturedBundleID: "com.apple.TextEdit")

        XCTAssertEqual(kb.pastes, 1)
        XCTAssertEqual(pb.current, "old", "original clipboard string must be restored")
    }

    // MARK: - Focus changed (paste-time)

    func testFocusChangedAbortsBeforePostingCmdV() async {
        let pb = FakePasteboard()
        let kb = FakeKeyboard()
        let fm = FakeFrontmost(); fm.bundleID = "com.tinyspeck.slackmacgap"

        let svc = PasteService(
            pasteboard: pb, keyboard: kb, frontmost: fm,
            restoreDelay: .zero
        )
        do {
            try await svc.paste(transcript: "hi", capturedBundleID: "com.apple.TextEdit")
            XCTFail("expected pasteFocusChanged")
        } catch SayMooreError.pasteFocusChanged(let captured, let current) {
            XCTAssertEqual(captured, "com.apple.TextEdit")
            XCTAssertEqual(current, "com.tinyspeck.slackmacgap")
            XCTAssertEqual(kb.pastes, 0, "must not Cmd-V into wrong app")
            XCTAssertEqual(pb.current, "hi", "transcript stays on clipboard for manual paste")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testCurrentBundleIDNilTreatedAsFocusChanged() async {
        let pb = FakePasteboard()
        let kb = FakeKeyboard()
        let fm = FakeFrontmost(); fm.bundleID = nil

        let svc = PasteService(
            pasteboard: pb, keyboard: kb, frontmost: fm,
            restoreDelay: .zero
        )
        do {
            try await svc.paste(transcript: "x", capturedBundleID: "com.apple.TextEdit")
            XCTFail("expected pasteFocusChanged")
        } catch SayMooreError.pasteFocusChanged {
            XCTAssertEqual(kb.pastes, 0)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - Clipboard contention

    func testClipboardContentionDuringRestoreWindow() async {
        let pb = FakePasteboard()
        pb.current = "before"
        pb.changeCount = 1
        let kb = FakeKeyboard()
        let fm = FakeFrontmost(); fm.bundleID = "com.apple.TextEdit"

        let svc = PasteService(
            pasteboard: pb, keyboard: kb, frontmost: fm,
            restoreDelay: .zero
        )
        // Simulate another process touching the clipboard between our changeCount snapshot
        // (taken right after setString) and the post-Cmd-V re-check. Hook the keyboard tap
        // so the bump happens after writtenCount has been captured.
        kb.onPostCmdV = {
            pb.changeCount += 1
            pb.current = "interloper"
        }

        do {
            try await svc.paste(transcript: "hi", capturedBundleID: "com.apple.TextEdit")
            XCTFail("expected pasteClipboardContended")
        } catch SayMooreError.pasteClipboardContended {
            XCTAssertEqual(pb.current, "interloper", "must not clobber whatever wrote after us")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - Orchestration order

    func testOrchestrationOrder() async throws {
        let pb = FakePasteboard()
        pb.current = "old"
        let kb = FakeKeyboard()
        let fm = FakeFrontmost(); fm.bundleID = "com.apple.TextEdit"

        let svc = PasteService(
            pasteboard: pb, keyboard: kb, frontmost: fm,
            restoreDelay: .zero
        )
        try await svc.paste(transcript: "hello", capturedBundleID: "com.apple.TextEdit")

        // The expected pasteboard ops, in order:
        //   1. clear (before set)
        //   2. set:hello
        //   3. clear (before restore)
        //   4. set:old  (restore)
        XCTAssertEqual(pb.ops, ["clear", "set:hello", "clear", "set:old"])
    }
}
