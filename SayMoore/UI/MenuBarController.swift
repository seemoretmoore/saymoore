import AppKit
import Combine

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let appState: AppState
    private let presets: PresetStore
    private let titleItem: NSMenuItem
    private var cancellables: Set<AnyCancellable> = []

    init(appState: AppState, presets: PresetStore) {
        self.appState = appState
        self.presets = presets
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.titleItem = NSMenuItem(title: "SayMoore (idle)", action: nil, keyEquivalent: "")
        super.init()

        if let button = statusItem.button {
            button.image = Self.image(for: .idle)
            button.image?.isTemplate = true
            button.toolTip = "SayMoore"
        }

        let menu = NSMenu()
        menu.addItem(titleItem)
        menu.addItem(.separator())

        let editItem = NSMenuItem(
            title: "Edit Presets…",
            action: #selector(editPresetsTapped),
            keyEquivalent: ""
        )
        editItem.target = self
        menu.addItem(editItem)

        let reloadItem = NSMenuItem(
            title: "Reload Presets",
            action: #selector(reloadPresetsTapped),
            keyEquivalent: ""
        )
        reloadItem.target = self
        menu.addItem(reloadItem)

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

    @objc private func editPresetsTapped() {
        // Re-materialize if the user deleted the file since launch —
        // activateFileViewerSelecting silently no-ops on missing paths.
        presets.ensureMaterialized()
        NSWorkspace.shared.activateFileViewerSelecting([presets.fileURL])
    }

    @objc private func reloadPresetsTapped() {
        do {
            try presets.reload()
            Log.app.info("presets reloaded from disk")
            NotificationCenterAdapter.shared.notify(
                title: "SayMoore",
                body: "Presets reloaded."
            )
        } catch {
            Log.app.error("preset reload failed: \(String(describing: error), privacy: .public)")
            NotificationCenterAdapter.shared.notify(
                title: "SayMoore",
                body: "presets.json invalid; previous preset retained."
            )
        }
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
