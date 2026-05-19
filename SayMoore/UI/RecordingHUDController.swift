import AppKit
import QuartzCore

/// Borderless click-through HUD shown on the active display while recording.
/// Configured to not steal focus, not block clicks, not appear in screenshots,
/// and to render above fullscreen apps via NSWindow.CollectionBehavior.
@MainActor
final class RecordingHUDController {
    static let labelCollapseDelay: TimeInterval = 1.2
    static let fadeInDuration: TimeInterval = 0.08
    static let fadeOutDuration: TimeInterval = 0.12

    private let panel: NSPanel
    private let labelView: NSTextField
    private let dotLayer: CALayer
    private var labelCollapseTimer: Timer?
    private var dotPulseTimer: Timer?
    private var dotDim: Bool = false

    /// Exposed for unit tests.
    var currentLabelText: String { labelView.stringValue }

    init() {
        let size = NSSize(width: 220, height: 30)
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.sharingType = .none
        panel.hidesOnDeactivate = false

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = size.height / 2
        background.layer?.masksToBounds = true

        let dotSize: CGFloat = 7
        dotLayer = CALayer()
        dotLayer.frame = NSRect(x: 12, y: (size.height - dotSize) / 2, width: dotSize, height: dotSize)
        dotLayer.cornerRadius = dotSize / 2
        dotLayer.backgroundColor = NSColor.systemRed.withAlphaComponent(0.85).cgColor
        background.layer?.addSublayer(dotLayer)

        labelView = NSTextField(labelWithString: "")
        labelView.frame = NSRect(x: 26, y: 0, width: size.width - 34, height: size.height)
        labelView.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        labelView.textColor = NSColor.secondaryLabelColor
        labelView.alignment = .left
        labelView.lineBreakMode = .byTruncatingTail
        labelView.cell?.usesSingleLineMode = true
        background.addSubview(labelView)

        panel.contentView = background
        panel.alphaValue = 0
    }

    func show(preset displayName: String) {
        let screen = ActiveDisplayResolver.resolve() ?? NSScreen.main
        let panelSize = panel.frame.size
        if let screen {
            panel.setFrame(Self.topCenterFrame(in: screen, size: panelSize), display: false)
        }
        labelView.stringValue = Self.expandedLabel(preset: displayName)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.fadeInDuration
            panel.animator().alphaValue = 1.0
        }
        startDotPulse()
        labelCollapseTimer?.invalidate()
        let timer = Timer(timeInterval: Self.labelCollapseDelay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.collapseLabel() }
        }
        RunLoop.main.add(timer, forMode: .common)
        labelCollapseTimer = timer
    }

    func hide() {
        labelCollapseTimer?.invalidate()
        labelCollapseTimer = nil
        stopDotPulse()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.fadeOutDuration
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in
            Task { @MainActor in panel.orderOut(nil) }
        })
    }

    /// Internal — exposed for tests so they can verify the post-collapse label
    /// without depending on the 1.2 s timer firing.
    func collapseLabel() {
        labelView.stringValue = Self.collapsedLabel
    }

    private func startDotPulse() {
        stopDotPulse()
        dotDim = false
        dotLayer.opacity = 1.0
        let timer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickDot() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dotPulseTimer = timer
    }

    private func stopDotPulse() {
        dotPulseTimer?.invalidate()
        dotPulseTimer = nil
        dotLayer.opacity = 1.0
    }

    private func tickDot() {
        dotDim.toggle()
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        dotLayer.opacity = dotDim ? 0.4 : 1.0
        CATransaction.commit()
    }

    static func expandedLabel(preset displayName: String) -> String {
        "Recording — \(displayName)"
    }

    static let collapsedLabel = "Recording"

    static func topCenterFrame(in screen: NSScreen, size: NSSize) -> NSRect {
        let visible = screen.visibleFrame
        let x = visible.midX - size.width / 2
        let y = visible.maxY - 40 - size.height
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}
