import Foundation
import os
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
    /// Post Cmd-Z (undo). Used by Command Mode to undo the prior paste before
    /// pasting the rewritten text. Treats paste-as-one-undo-unit (true in most
    /// macOS apps: Notes, Messages, Slack, BBEdit, TextEdit, Safari forms).
    ///
    /// Returns `true` if Cmd-Z was actually posted, `false` if the adapter
    /// aborted (e.g. a modifier key the hotkey driver hasn't released would
    /// turn Cmd-Z into Ctrl-Cmd-Z and the undo would silently no-op). Callers
    /// MUST NOT proceed with the dependent paste when `false` is returned.
    func postCmdZ() -> Bool
}

protocol FrontmostAdapter: Sendable {
    var bundleID: String? { get }
}

final class PasteService: Sendable {
    private let pasteboard: PasteboardAdapter
    private let keyboard: KeyboardAdapter
    private let frontmost: FrontmostAdapter
    private let restoreDelay: Duration

    static let defaultRestoreDelay: Duration = .milliseconds(400) // A2: raised from 200ms

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

    @MainActor // A3: NSPasteboard.general is main-thread-only; Task.sleep can resume off-main
    func paste(transcript: String, capturedBundleID: String?) async throws {
        let savedString = pasteboard.savedString()

        // A1: defer restores clipboard on every exit path (throw or normal return)
        defer {
            pasteboard.clearContents()
            if let s = savedString { pasteboard.setString(s) }
        }

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
        // A2: overrun hard-cap — only meaningful when delay is non-zero (zero = test mode)
        if restoreDelay > .zero && elapsed > restoreDelay * 2 {
            throw SayMooreError.pasteClipboardContended
        }

        guard pasteboard.changeCount == writtenCount else {
            throw SayMooreError.pasteClipboardContended
        }
    }

    /// Command Mode: undo the prior paste (Cmd-Z) and paste `rewritten` in its
    /// place. Same clipboard hygiene + focus check + overrun guard as `paste`.
    /// The 80 ms gap between Cmd-Z and Cmd-V gives the focused app time to
    /// commit the undo before we overwrite the pasteboard again.
    @MainActor
    func replacePriorPaste(rewritten: String, capturedBundleID: String?) async throws {
        let savedString = pasteboard.savedString()

        defer {
            pasteboard.clearContents()
            if let s = savedString { pasteboard.setString(s) }
        }

        // Focus check happens BEFORE the destructive undo — if the user
        // tabbed away, abort cleanly rather than sending Cmd-Z to a stale
        // app and losing unrelated state.
        let current = frontmost.bundleID
        if current != capturedBundleID || current == nil {
            throw SayMooreError.pasteFocusChanged(captured: capturedBundleID, current: current)
        }

        guard keyboard.postCmdZ() else {
            // Modifier flag (typically Ctrl from the Ctrl-Ctrl hotkey) is still
            // depressed at the kernel level; Cmd-Z would have arrived as
            // Ctrl-Cmd-Z and silently no-op'd, leaving the prior paste in
            // place. Abort *before* pasting the rewrite — otherwise the user
            // sees original + rewrite both in the document.
            throw SayMooreError.commandRewriteFailed(reason: "undo-blocked-modifier-stuck")
        }
        try? await Task.sleep(for: .milliseconds(80))

        // Re-check focus after the undo lands — Cmd-Z can pop a confirmation
        // dialog or steal focus in some apps; bail before pasting if so.
        let currentAfterUndo = frontmost.bundleID
        if currentAfterUndo != capturedBundleID {
            throw SayMooreError.pasteFocusChanged(captured: capturedBundleID, current: currentAfterUndo)
        }

        pasteboard.clearContents()
        pasteboard.setString(rewritten)
        let writtenCount = pasteboard.changeCount

        keyboard.postCmdV()

        let started = ContinuousClock.now
        try? await Task.sleep(for: restoreDelay)
        let elapsed = ContinuousClock.now - started
        if restoreDelay > .zero && elapsed > restoreDelay * 2 {
            throw SayMooreError.pasteClipboardContended
        }

        guard pasteboard.changeCount == writtenCount else {
            throw SayMooreError.pasteClipboardContended
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
        postCmdKey(virtualKey: 0x09) // 'v'
    }

    func postCmdZ() -> Bool {
        // The Ctrl-Ctrl activation hotkey occasionally leaves .maskControl set
        // in the session-level flags state after firing — measured up to ~80 ms
        // on M2 Ultra under Command Mode load. If we post Cmd-Z while Ctrl is
        // still held, the synthesized event arrives as Ctrl-Cmd-Z which is a
        // no-op in nearly every app. Wait briefly for the flag to drop;
        // bail out if it doesn't, so the caller knows not to paste the
        // dependent rewrite on top of an un-undone original.
        let waitDeadline = Date().addingTimeInterval(0.150)
        while Date() < waitDeadline,
              CGEventSource.flagsState(.combinedSessionState).contains(.maskControl) {
            Thread.sleep(forTimeInterval: 0.005)
        }
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let ctrl = flags.contains(.maskControl) ? "CTRL " : ""
        let opt  = flags.contains(.maskAlternate) ? "OPT " : ""
        let cmd  = flags.contains(.maskCommand) ? "CMD " : ""
        let shft = flags.contains(.maskShift) ? "SHIFT " : ""
        Log.paste.info("postCmdZ flagsState=[\(ctrl, privacy: .public)\(opt, privacy: .public)\(cmd, privacy: .public)\(shft, privacy: .public)] raw=\(flags.rawValue, privacy: .public)")
        if flags.contains(.maskControl) {
            Log.paste.error("postCmdZ aborted — Ctrl flag still set after 150ms wait; refusing to post Ctrl-Cmd-Z")
            return false
        }
        postCmdKey(virtualKey: 0x06) // 'z'
        return true
    }

    private func postCmdKey(virtualKey: CGKeyCode) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: true)
        let up   = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.setIntegerValueField(.eventSourceUserData, value: 0x5359)
        up?.setIntegerValueField(.eventSourceUserData, value: 0x5359)
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
