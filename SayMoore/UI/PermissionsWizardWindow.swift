// SayMoore/UI/PermissionsWizardWindow.swift
import AppKit
import SwiftUI

@MainActor
final class PermissionsWizardWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let viewModel: PermissionsViewModel
    private var continuation: CheckedContinuation<Void, Never>?
    private var recheckTask: Task<Void, Never>?

    init(checker: any PermissionChecker) {
        self.viewModel = PermissionsViewModel(checker: checker)
        self.window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "SayMoore Setup"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
        super.init()
        window.delegate = self
    }

    /// Suspends until all required permissions are granted (Notifications skippable).
    func present() async {
        viewModel.onAllGranted = { [weak self] in self?.finish() }
        let view = PermissionsWizardView(
            viewModel: viewModel,
            onQuit: { NSApp.terminate(nil) }
        )
        let hostingView = NSHostingView(rootView: view)
        window.contentView = hostingView
        window.setContentSize(hostingView.fittingSize)
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        // Continuation is set before windowDidBecomeKey fires on the next run-loop tick.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.continuation = cont
        }
    }

    func close() {
        window.orderOut(nil)
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        recheckTask?.cancel()
        recheckTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.viewModel.recheck()
            // TCC can lag ~500ms after user toggles a switch in Settings.
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self.viewModel.recheck()
        }
    }

    private func finish() {
        continuation?.resume()
        continuation = nil
    }
}
