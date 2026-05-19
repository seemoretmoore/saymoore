import AppKit
import QuartzCore

/// Soft glowing red disc that follows the cursor while recording. Same
/// non-intrusive guarantees as RecordingHUDController (click-through,
/// excluded from screenshots, no focus steal, above fullscreen apps).
@MainActor
final class CursorIndicatorController {
    private static let diameter: CGFloat = 14
    private static let panelSize: CGFloat = 56 // generous padding for glow blur
    private static let cursorOffsetX: CGFloat = 18 // sit to the right of the cursor
    private static let cursorOffsetY: CGFloat = -6 // slightly below the hotspot
    /// Pale Lifestream teal-green.
    private static let lifestream = NSColor(red: 0.45, green: 1.0, blue: 0.78, alpha: 1.0)
    private let panel: NSPanel
    private let glowLayer: CALayer
    private var mouseMonitor: Any?

    init() {
        let frameSize = NSSize(width: Self.panelSize, height: Self.panelSize)
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: frameSize),
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

        let host = NSView(frame: NSRect(origin: .zero, size: frameSize))
        host.wantsLayer = true
        host.layer = CALayer()

        glowLayer = CALayer()
        let inset = (Self.panelSize - Self.diameter) / 2
        glowLayer.frame = NSRect(x: inset, y: inset, width: Self.diameter, height: Self.diameter)
        glowLayer.cornerRadius = Self.diameter / 2
        glowLayer.backgroundColor = Self.lifestream.withAlphaComponent(0.55).cgColor
        glowLayer.shadowColor = Self.lifestream.cgColor
        glowLayer.shadowRadius = 10
        glowLayer.shadowOpacity = 0.9
        glowLayer.shadowOffset = .zero
        host.layer?.addSublayer(glowLayer)

        panel.contentView = host
        panel.alphaValue = 0
    }

    /// `globalPoint` is in global screen coordinates (NSEvent.mouseLocation
    /// convention — origin at primary-display bottom-left).
    func show(at globalPoint: NSPoint) {
        moveTo(globalPoint)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = RecordingHUDController.fadeInDuration
            panel.animator().alphaValue = 1.0
        }
        startPulse()
        startFollowingCursor()
    }

    func hide() {
        stopPulse()
        stopFollowingCursor()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = RecordingHUDController.fadeOutDuration
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in
            Task { @MainActor in panel.orderOut(nil) }
        })
    }

    private func moveTo(_ globalPoint: NSPoint) {
        let half = Self.panelSize / 2
        let frame = NSRect(
            x: globalPoint.x + Self.cursorOffsetX - half,
            y: globalPoint.y + Self.cursorOffsetY - half,
            width: Self.panelSize,
            height: Self.panelSize
        )
        panel.setFrame(frame, display: false)
    }

    private func startPulse() {
        glowLayer.removeAnimation(forKey: "lifestreamPulse")
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.55
        pulse.duration = 1.1
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glowLayer.add(pulse, forKey: "lifestreamPulse")
    }

    private func stopPulse() {
        glowLayer.removeAnimation(forKey: "lifestreamPulse")
    }

    private func startFollowingCursor() {
        stopFollowingCursor()
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.moveTo(NSEvent.mouseLocation)
            }
        }
    }

    private func stopFollowingCursor() {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
    }
}
