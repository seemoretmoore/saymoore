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
    func postCmdZ()
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

        keyboard.postCmdZ()
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

    func postCmdZ() {
        // H2 diagnosis: log live modifier state at the instant we post Cmd-Z.
        // If .maskControl is set, the Ctrl-Ctrl hotkey left a stuck flag and
        // Cmd-Z is actually being delivered as Ctrl-Cmd-Z (no-op).
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let ctrl = flags.contains(.maskControl) ? "CTRL " : ""
        let opt  = flags.contains(.maskAlternate) ? "OPT " : ""
        let cmd  = flags.contains(.maskCommand) ? "CMD " : ""
        let shft = flags.contains(.maskShift) ? "SHIFT " : ""
        Log.paste.info("postCmdZ flagsState=[\(ctrl, privacy: .public)\(opt, privacy: .public)\(cmd, privacy: .public)\(shft, privacy: .public)] raw=\(flags.rawValue, privacy: .public)")
        postCmdKey(virtualKey: 0x06) // 'z'
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
