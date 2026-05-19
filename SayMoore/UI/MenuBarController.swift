import AppKit
import Combine

@MainActor
final class MenuBarController: NSObject {
    /// Tick interval — drives both the half-tone pulse and the M:SS counter.
    static let pulseInterval: TimeInterval = 1.0

    private let statusItem: NSStatusItem
    private let appState: AppState
    private let presets: PresetStore
    private let titleItem: NSMenuItem
    private var cancellables: Set<AnyCancellable> = []
    private var pulseTimer: Timer?
    private var pulseDim: Bool = false
    private var recordingStartedAt: Date?
    private var phase: PipelineCoordinator.LengthCapPhase = .idle

    init(appState: AppState, presets: PresetStore) {
        self.appState = appState
        self.presets = presets
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.titleItem = NSMenuItem(title: "SayMoore (idle)", action: nil, keyEquivalent: "")
        super.init()

        if let button = statusItem.button {
            button.image = Self.image(for: .idle, phase: .idle)
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

    /// Called by AppDelegate via PipelineCoordinator.onLengthCapPhase. Rebuilds
    /// the menu-bar icon with the appropriate coloured pill backing.
    func setPhase(_ newPhase: PipelineCoordinator.LengthCapPhase) {
        guard phase != newPhase else { return }
        phase = newPhase
        refreshIcon()
    }

    private func apply(_ state: AppState.State) {
        refreshIcon()
        titleItem.title = "SayMoore (\(Self.label(for: state)))"
        if state == .recording {
            startPulse()
        } else {
            stopPulse()
        }
    }

    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        let img = Self.image(for: appState.state, phase: phase)
        button.image = img
        button.image?.isTemplate = (phase == .idle)
    }

    private func startPulse() {
        guard pulseTimer == nil else { return }
        pulseDim = false
        recordingStartedAt = Date()
        // Render the initial "0:00" immediately so the user sees the counter
        // appear at hotkey-press time rather than waiting one second for the
        // first tick.
        statusItem.button?.title = Self.formatElapsed(0)
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
        if let start = recordingStartedAt {
            button.title = Self.formatElapsed(Date().timeIntervalSince(start))
        }
    }

    static func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }


    private static func image(for state: AppState.State, phase: PipelineCoordinator.LengthCapPhase) -> NSImage? {
        let symbolName = (state == .recording) ? "mic.fill" : "mic"
        let accessibility = (state == .recording) ? "SayMoore recording" : "SayMoore"
        if phase == .idle {
            return NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibility)
        }
        return pillImage(symbolName: symbolName, accessibility: accessibility, fill: pillColor(for: phase))
    }

    private static func pillColor(for phase: PipelineCoordinator.LengthCapPhase) -> NSColor {
        switch phase {
        case .normal:  return .systemGreen
        case .caution: return .systemYellow
        case .warning: return .systemRed
        case .idle:    return .clear
        }
    }

    private static func pillImage(symbolName: String, accessibility: String, fill: NSColor) -> NSImage {
        let size = NSSize(width: 22, height: 18)
        let radius: CGFloat = 4
        let symbolPoint: CGFloat = 12
        let img = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius)
            fill.setFill()
            path.fill()
            guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibility) else {
                return true
            }
            let cfg = NSImage.SymbolConfiguration(pointSize: symbolPoint, weight: .semibold)
            let configured = symbol.withSymbolConfiguration(cfg) ?? symbol
            let symbolSize = configured.size
            let target = NSRect(
                x: (rect.width  - symbolSize.width)  / 2,
                y: (rect.height - symbolSize.height) / 2,
                width:  symbolSize.width,
                height: symbolSize.height
            )
            configured.draw(in: target)
            // Tint the symbol white so it reads on the coloured background.
            NSColor.white.set()
            target.fill(using: .sourceAtop)
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
