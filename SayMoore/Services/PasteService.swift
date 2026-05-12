import Foundation
#if canImport(AppKit)
@preconcurrency import AppKit
#endif

protocol PasteboardAdapter: Sendable {
    var changeCount: Int { get }
    func savedString() -> String?
    func clearContents()
    func setString(_ s: String)
}

protocol KeyboardAdapter: Sendable {
    func postCmdV()
}

protocol FrontmostAdapter: Sendable {
    var bundleID: String? { get }
}

final class PasteService: Sendable {
    private let pasteboard: PasteboardAdapter
    private let keyboard: KeyboardAdapter
    private let frontmost: FrontmostAdapter
    private let restoreDelay: Duration

    static let defaultRestoreDelay: Duration = .milliseconds(200)

    init(
        pasteboard: PasteboardAdapter,
        keyboard: KeyboardAdapter,
        frontmost: FrontmostAdapter,
        restoreDelay: Duration = PasteService.defaultRestoreDelay
    ) {
        self.pasteboard = pasteboard
        self.keyboard = keyboard
        self.frontmost = frontmost
        self.restoreDelay = restoreDelay
    }

    func paste(transcript: String, capturedBundleID: String?) async throws {
        let savedString = pasteboard.savedString()

        pasteboard.clearContents()
        pasteboard.setString(transcript)
        let writtenCount = pasteboard.changeCount

        let current = frontmost.bundleID
        if current != capturedBundleID || current == nil {
            throw SayMooreError.pasteFocusChanged(captured: capturedBundleID, current: current)
        }

        keyboard.postCmdV()

        let started = ContinuousClock.now
        try? await Task.sleep(for: restoreDelay)
        let elapsed = ContinuousClock.now - started
        if elapsed > Self.defaultRestoreDelay * 2 {
            Log.paste.warning("restore delay exceeded: \(String(describing: elapsed), privacy: .public)")
        }

        guard pasteboard.changeCount == writtenCount else {
            throw SayMooreError.pasteClipboardContended
        }

        pasteboard.clearContents()
        if let s = savedString {
            pasteboard.setString(s)
        }
    }
}

#if canImport(AppKit)
struct NSPasteboardAdapter: PasteboardAdapter {
    var changeCount: Int { NSPasteboard.general.changeCount }
    func savedString() -> String? { NSPasteboard.general.string(forType: .string) }
    func clearContents() { NSPasteboard.general.clearContents() }
    func setString(_ s: String) {
        NSPasteboard.general.setString(s, forType: .string)
    }
}

struct CGEventKeyboardAdapter: KeyboardAdapter {
    func postCmdV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 0x09 // 'v'
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let up   = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}

struct NSWorkspaceFrontmostAdapter: FrontmostAdapter {
    var bundleID: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}
#endif
