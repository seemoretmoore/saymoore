import AppKit
import QuartzCore

/// Borderless click-through HUD shown anchored to the bottom of the active
/// window while recording. Click-through, excluded from screenshots, no focus
/// steal, renders above fullscreen apps via NSWindow.CollectionBehavior.
@MainActor
final class RecordingHUDController {
    static let fadeInDuration: TimeInterval = 0.08
    static let fadeOutDuration: TimeInterval = 0.12

    private static let pillSize = NSSize(width: 130, height: 30)
    private static let collapsedWidth: CGFloat = 130
    private static let maxExpandedWidth: CGFloat = 340
    private static let dividerWidth: CGFloat = 1
    private static let dividerLeftMargin: CGFloat = 6
    private static let dividerRightMargin: CGFloat = 8
    private static let textRightMargin: CGFloat = 12
    private static let textFontSize: CGFloat = 11
    private static let barCount = 12
    private static let barWidth: CGFloat = 4
    private static let barGap: CGFloat = 4
    private static let barAreaX: CGFloat = 24
    private static let barMaxHeight: CGFloat = 22
    private static let barMinHeight: CGFloat = 4
    /// Distance from the active window's bottom edge to the TOP of the pill.
    /// Positive value = pill top sits this many px above the window's bottom
    /// edge (the rest of the pill hangs below the window).
    private static let pillTopAboveWindowBottom: CGFloat = 4
    /// FFVII Lifestream — luminous green with a touch of cyan.
    private static let lifestream = NSColor(red: 0.4, green: 1.0, blue: 0.6, alpha: 1.0)

    private let panel: NSPanel
    private let dotLayer: CALayer
    private var barLayers: [CALayer] = []
    private var levelBuffer: [Float] = Array(repeating: 0, count: barCount)
    private var displayBuffer: [Float] = Array(repeating: 0, count: barCount)
    private var dotPulseTimer: Timer?
    private var dotDim: Bool = false
    private var textField: NSTextField!
    private var dividerLayer: CALayer!
    private var lastCommitted: String = ""
    private var lastActive: String = ""
    nonisolated(unsafe) private var appActivationObserver: NSObjectProtocol?

    /// Exposed for unit tests — current smoothed bar amplitudes (0...1).
    var displayLevels: [Float] { displayBuffer }

    init() {
        let size = Self.pillSize
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
        background.isEmphasized = true
        background.wantsLayer = true
        background.layer?.cornerRadius = size.height / 2
        // Clip everything (bar shadows, highlight gradient) to the rounded pill.
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.white.withAlphaComponent(0.32).cgColor

        // Inner highlight gradient — white sheen on the top half, fades to clear.
        // Gives the pill a glass-y reflection without overpowering the bars.
        let highlight = CAGradientLayer()
        highlight.frame = NSRect(origin: .zero, size: size)
        highlight.colors = [
            NSColor.white.withAlphaComponent(0.20).cgColor,
            NSColor.white.withAlphaComponent(0.04).cgColor,
            NSColor.clear.cgColor,
        ]
        highlight.locations = [0.0, 0.5, 1.0]
        highlight.startPoint = CGPoint(x: 0.5, y: 1.0)  // top
        highlight.endPoint = CGPoint(x: 0.5, y: 0.0)    // bottom
        background.layer?.addSublayer(highlight)

        let dotSize: CGFloat = 7
        dotLayer = CALayer()
        dotLayer.frame = NSRect(x: 10, y: (size.height - dotSize) / 2, width: dotSize, height: dotSize)
        dotLayer.cornerRadius = dotSize / 2
        dotLayer.backgroundColor = NSColor.systemRed.withAlphaComponent(0.85).cgColor
        background.layer?.addSublayer(dotLayer)

        let lifestreamCG = Self.lifestream.cgColor
        for i in 0..<Self.barCount {
            let layer = CALayer()
            let x = Self.barAreaX + CGFloat(i) * (Self.barWidth + Self.barGap)
            let y = (size.height - Self.barMinHeight) / 2
            layer.frame = NSRect(x: x, y: y, width: Self.barWidth, height: Self.barMinHeight)
            layer.cornerRadius = Self.barWidth / 2
            layer.backgroundColor = lifestreamCG
            // Lifestream glow.
            layer.shadowColor = lifestreamCG
            layer.shadowRadius = 4
            layer.shadowOpacity = 0.9
            layer.shadowOffset = .zero
            background.layer?.addSublayer(layer)
            barLayers.append(layer)
        }

        let divider = CALayer()
        divider.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
        let dividerX = Self.barAreaX + CGFloat(Self.barCount) * (Self.barWidth + Self.barGap) + Self.dividerLeftMargin
        divider.frame = NSRect(
            x: dividerX,
            y: (size.height - Self.barMaxHeight) / 2,
            width: Self.dividerWidth,
            height: Self.barMaxHeight
        )
        divider.opacity = 0
        background.layer?.addSublayer(divider)
        self.dividerLayer = divider

        let tf = NSTextField(labelWithString: "")
        tf.font = NSFont.systemFont(ofSize: Self.textFontSize, weight: .regular)
        tf.textColor = NSColor.white
        tf.backgroundColor = .clear
        tf.isBezeled = false
        tf.isEditable = false
        tf.isSelectable = false
        tf.lineBreakMode = .byTruncatingHead
        tf.usesSingleLineMode = true
        tf.cell?.truncatesLastVisibleLine = true
        tf.alphaValue = 0
        let textX = dividerX + Self.dividerWidth + Self.dividerRightMargin
        tf.frame = NSRect(
            x: textX,
            y: 0,
            width: 0,
            height: size.height
        )
        background.addSubview(tf)
        self.textField = tf

        panel.contentView = background
        panel.alphaValue = 0
    }

    func show() {
        let frame = Self.frameForActiveContext(panelSize: panel.frame.size)
        panel.setFrame(frame, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.fadeInDuration
            panel.animator().alphaValue = 1.0
        }
        startDotPulse()
        startAppFollowing()
    }

    func hide() {
        stopAppFollowing()
        stopDotPulse()
        resetBars()
        lastCommitted = ""
        lastActive = ""
        textField.attributedStringValue = NSAttributedString(string: "")
        textField.alphaValue = 0
        dividerLayer.opacity = 0
        // Snap pill back to collapsed width for next show().
        var f = panel.frame
        f.size.width = Self.collapsedWidth
        panel.setFrame(f, display: false)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.fadeOutDuration
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in
            Task { @MainActor in panel.orderOut(nil) }
        })
    }

    /// Push a new normalized amplitude (0…1) into the rolling buffer and
    /// redraw bars. Safe to call when the panel is hidden.
    func updateLevel(_ level: Float) {
        let clamped = max(0, min(1, level))
        levelBuffer.removeFirst()
        levelBuffer.append(clamped)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in 0..<Self.barCount {
            displayBuffer[i] = 0.4 * displayBuffer[i] + 0.6 * levelBuffer[i]
            let h = Self.barMinHeight + CGFloat(displayBuffer[i]) * (Self.barMaxHeight - Self.barMinHeight)
            let x = Self.barAreaX + CGFloat(i) * (Self.barWidth + Self.barGap)
            let y = (Self.pillSize.height - h) / 2
            barLayers[i].frame = NSRect(x: x, y: y, width: Self.barWidth, height: h)
        }
        CATransaction.commit()
    }

    /// Update the partial-transcript display. Animates the pill width to fit.
    /// Empty strings collapse the pill back to waveform-only.
    func updatePartialText(committed: String, active: String) {
        lastCommitted = committed
        lastActive = active

        let combined = committed + active
        if combined.isEmpty {
            animatePillWidth(to: Self.collapsedWidth)
            dividerLayer.opacity = 0
            textField.alphaValue = 0
            textField.attributedStringValue = NSAttributedString(string: "")
            return
        }

        let attr = NSMutableAttributedString()
        let baseFont = NSFont.systemFont(ofSize: Self.textFontSize, weight: .regular)
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: NSColor.white,
        ]
        attr.append(NSAttributedString(string: committed, attributes: baseAttrs))
        let italicFont = Self.italicFont(baseFont)
        let activeAttrs: [NSAttributedString.Key: Any] = [
            .font: italicFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
        ]
        attr.append(NSAttributedString(string: active, attributes: activeAttrs))
        textField.attributedStringValue = attr
        textField.alphaValue = 1
        dividerLayer.opacity = 1

        // Measure + clamp.
        let measured = attr.size().width + 4  // text padding fudge
        let dividerX = Self.barAreaX + CGFloat(Self.barCount) * (Self.barWidth + Self.barGap) + Self.dividerLeftMargin
        let textStartX = dividerX + Self.dividerWidth + Self.dividerRightMargin
        let target = min(Self.maxExpandedWidth, textStartX + measured + Self.textRightMargin)
        animatePillWidth(to: target)
        textField.frame.size.width = target - textStartX - Self.textRightMargin
    }

    private func animatePillWidth(to newWidth: CGFloat) {
        var f = panel.frame
        let delta = newWidth - f.width
        f.origin.x -= delta / 2
        f.size.width = newWidth
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(f, display: false)
        }
    }

    private static func italicFont(_ base: NSFont) -> NSFont {
        let desc = base.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: desc, size: base.pointSize) ?? base
    }

    private func resetBars() {
        levelBuffer = Array(repeating: 0, count: Self.barCount)
        displayBuffer = Array(repeating: 0, count: Self.barCount)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in 0..<Self.barCount {
            let x = Self.barAreaX + CGFloat(i) * (Self.barWidth + Self.barGap)
            let y = (Self.pillSize.height - Self.barMinHeight) / 2
            barLayers[i].frame = NSRect(x: x, y: y, width: Self.barWidth, height: Self.barMinHeight)
        }
        CATransaction.commit()
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

    private func startAppFollowing() {
        stopAppFollowing()
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.relocate()
            }
        }
    }

    private func stopAppFollowing() {
        if let obs = appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            appActivationObserver = nil
        }
    }

    /// Recompute and animate the pill into the new active window's anchor.
    /// CGWindowList can be stale at the instant `didActivate` fires; defer
    /// briefly so the new app's window has been promoted to the top of the
    /// z-order.
    private func relocate() {
        let panelSize = panel.frame.size
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let target = Self.frameForActiveContext(panelSize: panelSize)
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.15
                    ctx.allowsImplicitAnimation = true
                    self.panel.animator().setFrame(target, display: false)
                }
            }
        }
    }

    /// Resolves the HUD's screen frame: anchored to the bottom edge of the
    /// active window when one is available, otherwise top-center of the
    /// active display.
    static func frameForActiveContext(panelSize: NSSize) -> NSRect {
        if let windowFrame = ActiveDisplayResolver.resolveWindowFrame() {
            return bottomCenterFrame(in: windowFrame, size: panelSize)
        }
        if let screen = ActiveDisplayResolver.resolve() {
            return topCenterFrame(in: screen, size: panelSize)
        }
        return NSRect(origin: .zero, size: panelSize)
    }

    /// Position `size` horizontally centered on `windowFrame`. The TOP of the
    /// pill sits `pillTopAboveWindowBottom` px above the window's bottom edge
    /// — i.e., the pill hangs below the window with its top edge slightly
    /// crossing into the window's lower region.
    static func bottomCenterFrame(in windowFrame: NSRect, size: NSSize) -> NSRect {
        let x = windowFrame.midX - size.width / 2
        // pill.maxY = window.minY + pillTopAboveWindowBottom
        // → pill.minY = pill.maxY - size.height
        let y = windowFrame.minY + Self.pillTopAboveWindowBottom - size.height
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    static func topCenterFrame(in screen: NSScreen, size: NSSize) -> NSRect {
        let visible = screen.visibleFrame
        let x = visible.midX - size.width / 2
        let y = visible.maxY - 40 - size.height
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}
