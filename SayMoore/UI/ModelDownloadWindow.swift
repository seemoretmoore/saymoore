import AppKit
import SwiftUI
import Combine

@MainActor
final class ModelDownloadWindow {
    private let window: NSWindow
    private let bootstrap: ModelBootstrap
    private var cancellable: AnyCancellable?
    private var continuation: CheckedContinuation<Void, Never>?
    private var onRetry: () -> Void = {}

    init(bootstrap: ModelBootstrap) {
        self.bootstrap = bootstrap
        self.window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "SayMoore Setup"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
    }

    func present(onRetry: @escaping () -> Void) async {
        self.onRetry = onRetry
        let view = ModelDownloadView(
            bootstrap: bootstrap,
            onRetry: { [weak self] in self?.onRetry() },
            onQuit: { NSApp.terminate(nil) }
        )
        window.contentView = NSHostingView(rootView: view)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.continuation = cont
            self.cancellable = bootstrap.$phase
                .receive(on: RunLoop.main)
                .sink { [weak self] phase in
                    guard let self else { return }
                    if case .ready = phase {
                        self.finish()
                    }
                }
        }
    }

    func close() {
        window.orderOut(nil)
    }

    private func finish() {
        cancellable?.cancel()
        cancellable = nil
        continuation?.resume()
        continuation = nil
    }
}
