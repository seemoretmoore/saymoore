import AppKit
import SwiftUI

/// Hosts the SwiftUI `SettingsView` inside a standard utility-style NSWindow.
/// Lifetime-managed by AppDelegate; menu-bar "Settings…" action opens (or
/// re-foregrounds) a single shared instance.
@MainActor
final class SettingsWindow: NSObject {
    private let window: NSWindow
    private let viewModel: SettingsViewModel

    init(
        presets: PresetStore,
        onOpenPresetsFile: @escaping () -> Void,
        onReloadPresets: @escaping () -> Void,
        onCheckForPresetUpdates: @escaping () -> Void
    ) {
        let vm = SettingsViewModel(presets: presets)
        self.viewModel = vm
        let hosting = NSHostingController(rootView: SettingsView(
            viewModel: vm,
            onOpenPresetsFile: onOpenPresetsFile,
            onReloadPresets: onReloadPresets,
            onCheckForPresetUpdates: onCheckForPresetUpdates
        ))
        self.window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.title = "SayMoore Settings"
        window.isReleasedWhenClosed = false
        // `.canJoinAllSpaces` (utility-style follow-the-user) conflicts with
        // `.moveToActiveSpace` (jump-here-now) and on macOS 14+ causes
        // makeKeyAndOrderFront to land the window on an inactive Space —
        // visible=true in logs, but invisible to the user. Drop the
        // follow-style flag; add fullScreenAuxiliary so the window layers
        // over a fullscreen app instead of switching Spaces.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.center()
        super.init()
    }

    /// Pull fresh state from PresetStore before showing — covers the
    /// case where the user edited presets.json by hand between sessions.
    func show() {
        // Re-center if the saved frame ended up offscreen (e.g. external
        // display was disconnected since last open) — otherwise the window
        // orders front onto a screen that doesn't exist anymore.
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(window.frame) }
        if !onScreen { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Refresh AFTER activation — a refresh throw must never prevent the
        // window from appearing.
        viewModel.refresh()
        Log.app.info("settings.show: visible=\(self.window.isVisible, privacy: .public) frame=\(NSStringFromRect(self.window.frame), privacy: .public) screen=\(self.window.screen?.localizedName ?? "nil", privacy: .public)")
    }

    /// Called by AppDelegate after a FSEvents-driven reload of presets.json.
    /// Refresh the VM only if the window is visible (avoids wasted work +
    /// unexpected state changes for users who haven't opened Settings).
    func notifyExternalReload() {
        guard window.isVisible else { return }
        viewModel.refresh()
    }
}
