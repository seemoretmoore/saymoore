import AppKit
import Combine

@MainActor
final class MenuBarController: NSObject {
    /// Tick interval — drives both the half-tone pulse and the M:SS counter.
    static let pulseInterval: TimeInterval = 1.0

    private let statusItem: NSStatusItem
    private let appState: AppState
    private let presets: PresetStore
    private let historyStore: HistoryStore?
    private let titleItem: NSMenuItem
    private var cancellables: Set<AnyCancellable> = []
    private var pulseTimer: Timer?
    private var pulseDim: Bool = false
    private var recordingStartedAt: Date?
    private var phase: PipelineCoordinator.LengthCapPhase = .idle
    private var badge: NotificationCoordinator.Badge?

    init(appState: AppState, presets: PresetStore, historyStore: HistoryStore? = nil) {
        self.appState = appState
        self.presets = presets
        self.historyStore = historyStore
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.titleItem = NSMenuItem(title: "SayMoore (idle)", action: nil, keyEquivalent: "")
        super.init()

        if let button = statusItem.button {
            button.image = Self.image(for: .idle, phase: .idle, elapsed: 0)
            button.image?.isTemplate = true
            button.toolTip = "SayMoore"
            button.imagePosition = .imageLeading
            button.title = ""
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

        let debugLogItem = NSMenuItem(
            title: "Open Debug Log in Finder",
            action: #selector(openDebugLogTapped),
            keyEquivalent: ""
        )
        debugLogItem.target = self
        menu.addItem(.separator())
        menu.addItem(debugLogItem)

        let updatesItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(UpdaterService.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updatesItem.target = UpdaterService.shared
        menu.addItem(.separator())
        menu.addItem(updatesItem)

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
        // Shared helper posts the existing "preset error" banner on hard
        // failure and the new vocabulary-warning banner on partial failure
        // (deduped on PresetStore). The success toast below is menu-action
        // specific feedback that the FSEvent path intentionally lacks.
        let ok = AppDelegate.reloadPresetsAndNotifyOnFailure(presets: presets)
        if ok {
            Log.app.info("presets reloaded from disk")
            NotificationCenterAdapter.shared.notify(
                title: "SayMoore",
                body: "Presets reloaded."
            )
        }
    }

    @objc private func openDebugLogTapped() {
        guard let store = historyStore else {
            NSSound.beep()
            return
        }
        Task {
            let url = await store.debugLogURL
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                // Reveal the parent .noindex dir if the file doesn't exist yet.
                NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
            }
        }
    }

    /// Called by AppDelegate via PipelineCoordinator.onLengthCapPhase. Rebuilds
    /// the menu-bar icon with the appropriate coloured pill backing.
    func setPhase(_ newPhase: PipelineCoordinator.LengthCapPhase) {
        guard phase != newPhase else { return }
        phase = newPhase
        refreshIcon()
    }

    func setBadge(_ badge: NotificationCoordinator.Badge?) {
        guard self.badge != badge else { return }
        self.badge = badge
        refreshIcon()
        titleItem.title = Self.titleString(for: appState.state, badge: badge)
    }

    private func apply(_ state: AppState.State) {
        refreshIcon()
        titleItem.title = Self.titleString(for: state, badge: badge)
        if state == .recording {
            startPulse()
        } else {
            stopPulse()
        }
    }

    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        let elapsed = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let img = Self.image(for: appState.state, phase: phase, elapsed: elapsed)
        button.image = img
        button.image?.isTemplate = (appState.state != .recording)
        // Title is baked into the pill image during recording; clear the
        // status-item title slot so it doesn't render twice.
        button.title = ""
        button.toolTip = badge?.label ?? "SayMoore"
    }

    private static func titleString(for state: AppState.State, badge: NotificationCoordinator.Badge?) -> String {
        "SayMoore (\(label(for: state)))" + (badge.map { " — ⚠︎ \($0.label)" } ?? "")
    }

    private func startPulse() {
        guard pulseTimer == nil else { return }
        pulseDim = false
        recordingStartedAt = Date()
        // Render the initial "0:00" pill immediately so the user sees the
        // counter at hotkey-press time rather than waiting one second.
        refreshIcon()
        // .common so the pulse keeps ticking while the user has the menu open.
        let timer = Timer(timeInterval: Self.pulseInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickPulse()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pulseTimer = timer
    }

    private func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        pulseDim = false
        recordingStartedAt = nil
        if let button = statusItem.button {
            button.appearsDisabled = false
            button.title = ""
        }
    }

    private func tickPulse() {
        pulseDim.toggle()
        guard let button = statusItem.button else { return }
        button.appearsDisabled = pulseDim
        // Time text is baked into the pill image, so regenerate it each tick.
        refreshIcon()
    }

    static func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }


    private static func image(
        for state: AppState.State,
        phase: PipelineCoordinator.LengthCapPhase,
        elapsed: TimeInterval
    ) -> NSImage? {
        if state == .recording {
            // Always show a pill with the elapsed timer baked in while
            // recording. If the phase callback hasn't fired yet at the very
            // start, default to green so the user never sees a blank pill.
            let fill = pillColor(forRecordingPhase: phase) ?? .systemGreen
            return pillImage(text: formatElapsed(elapsed), fill: fill)
        }
        return NSImage(systemSymbolName: "mic", accessibilityDescription: "SayMoore")
    }

    private static func pillColor(forRecordingPhase phase: PipelineCoordinator.LengthCapPhase) -> NSColor? {
        switch phase {
        case .normal:  return .systemGreen
        case .caution: return .systemYellow
        case .warning: return .systemRed
        case .idle:    return nil
        }
    }

    private static func pillImage(text: String, fill: NSColor) -> NSImage {
        let height: CGFloat = 18
        let radius: CGFloat = 4
        let hPadding: CGFloat = 6
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let textSize = attributed.size()
        let width = ceil(textSize.width) + hPadding * 2
        let size = NSSize(width: width, height: height)
        let accessibility = "SayMoore recording \(text)"
        let img = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius)
            fill.setFill()
            path.fill()
            let drawRect = NSRect(
                x: (rect.width  - textSize.width)  / 2,
                y: (rect.height - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            attributed.draw(in: drawRect)
            return true
        }
        img.isTemplate = false
        img.accessibilityDescription = accessibility
        return img
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
