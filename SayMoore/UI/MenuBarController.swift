import AppKit
import Combine

@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let appState: AppState
    private let titleItem: NSMenuItem
    private var cancellables: Set<AnyCancellable> = []

    init(appState: AppState) {
        self.appState = appState
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.titleItem = NSMenuItem(title: "SayMoore (idle)", action: nil, keyEquivalent: "")

        if let button = statusItem.button {
            button.image = Self.image(for: .idle)
            button.image?.isTemplate = true
            button.toolTip = "SayMoore"
        }

        let menu = NSMenu()
        menu.addItem(titleItem)
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit SayMoore",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        statusItem.menu = menu

        appState.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.apply(state) }
            .store(in: &cancellables)
    }

    private func apply(_ state: AppState.State) {
        statusItem.button?.image = Self.image(for: state)
        statusItem.button?.image?.isTemplate = true
        titleItem.title = "SayMoore (\(Self.label(for: state)))"
    }

    private static func image(for state: AppState.State) -> NSImage? {
        switch state {
        case .recording:
            return NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "SayMoore recording")
        default:
            return NSImage(systemSymbolName: "mic", accessibilityDescription: "SayMoore")
        }
    }

    private static func label(for state: AppState.State) -> String {
        switch state {
        case .idle: return "idle"
        case .recording: return "recording"
        case .transcribing: return "transcribing"
        case .cleaning: return "cleaning"
        case .pasting: return "pasting"
        case .error: return "error"
        }
    }
}
