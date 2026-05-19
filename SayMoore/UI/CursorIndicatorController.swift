import AppKit
import QuartzCore

/// Small translucent red ring shown at the cursor position captured at hotkey
/// press. Fades in over 80 ms, persists until recording ends, fades out over
/// 120 ms. Same non-intrusive guarantees as RecordingHUDController.
@MainActor
final class CursorIndicatorController {
    private static let diameter: CGFloat = 24
    private let panel: NSPanel

    init() {
        let size = NSSize(width: Self.diameter, height: Self.diameter)
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

        let host = NSView(frame: NSRect(origin: .zero, size: size))
        host.wantsLayer = true
        let ring = CALayer()
        ring.frame = NSRect(origin: .zero, size: size)
        ring.cornerRadius = Self.diameter / 2
        ring.borderColor = NSColor.systemRed.withAlphaComponent(0.9).cgColor
        ring.borderWidth = 2
        ring.backgroundColor = NSColor.clear.cgColor
        host.layer = CALayer()
        host.layer?.addSublayer(ring)
        panel.contentView = host
        panel.alphaValue = 0
    }

    /// `globalPoint` is in global screen coordinates (NSEvent.mouseLocation
    /// convention — origin at primary-display bottom-left).
    func show(at globalPoint: NSPoint) {
        let frame = NSRect(
            x: globalPoint.x - Self.diameter / 2,
            y: globalPoint.y - Self.diameter / 2,
            width: Self.diameter,
            height: Self.diameter
        )
        panel.setFrame(frame, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = RecordingHUDController.fadeInDuration
            panel.animator().alphaValue = 1.0
        }
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = RecordingHUDController.fadeOutDuration
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in
            Task { @MainActor in panel.orderOut(nil) }
        })
    }
}
