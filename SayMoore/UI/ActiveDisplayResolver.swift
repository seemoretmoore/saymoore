@preconcurrency import AppKit
import CoreGraphics

/// Picks the NSScreen that should host the recording HUD: the screen containing
/// the midpoint of the frontmost app's topmost on-screen window. Falls back to
/// `NSScreen.main` then `NSScreen.screens.first` when no usable window is found.
enum ActiveDisplayResolver {
    @MainActor
    static func resolve() -> NSScreen? {
        let app = NSWorkspace.shared.frontmostApplication
        let screens = NSScreen.screens
        let infos = defaultWindowList()
        return pickScreen(
            frontmostPID: app?.processIdentifier,
            windowInfos: infos,
            screens: screens.map { ScreenFrame(frame: $0.frame, screen: $0) }
        )?.screen ?? NSScreen.main ?? screens.first
    }

    /// Pure decision logic, unit-testable in isolation. Returns the matching
    /// `ScreenFrame` (whose `frame` contains the window midpoint) or `nil` if
    /// no frontmost window is found.
    static func pickScreen(
        frontmostPID: pid_t?,
        windowInfos: [[String: Any]],
        screens: [ScreenFrame]
    ) -> ScreenFrame? {
        guard let pid = frontmostPID else { return nil }
        let owned = windowInfos.filter {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid
        }
        guard let top = owned.first,
              let bounds = top[kCGWindowBounds as String] as? [String: CGFloat],
              let x = bounds["X"], let y = bounds["Y"],
              let w = bounds["Width"], let h = bounds["Height"]
        else { return nil }
        let midXcg = x + w / 2
        let midYcg = y + h / 2
        // CGWindow bounds use a flipped origin (top-left of the primary
        // display). NSScreen uses bottom-left of the primary display.
        // Anchor flip on the primary screen's maxY.
        guard let primary = screens.first else { return nil }
        let primaryMaxY = primary.frame.maxY
        let pt = NSPoint(x: midXcg, y: primaryMaxY - midYcg)
        return screens.first(where: { $0.frame.contains(pt) })
    }

    /// Resolves the frontmost window's frame in `NSScreen` coordinates
    /// (origin bottom-left of the primary display), or `nil` when no usable
    /// window is found. Used by the recording HUD to anchor itself to the
    /// active window's bottom edge.
    @MainActor
    static func resolveWindowFrame() -> NSRect? {
        let app = NSWorkspace.shared.frontmostApplication
        let screens = NSScreen.screens
        let infos = defaultWindowList()
        return pickWindowFrame(
            frontmostPID: app?.processIdentifier,
            windowInfos: infos,
            primaryFrame: screens.first?.frame
        )
    }

    /// Pure flip-and-find logic for `resolveWindowFrame`. Returns the frontmost
    /// window's bounds in NS coords (bottom-left origin on the primary screen).
    static func pickWindowFrame(
        frontmostPID: pid_t?,
        windowInfos: [[String: Any]],
        primaryFrame: NSRect?
    ) -> NSRect? {
        guard let pid = frontmostPID, let primary = primaryFrame else { return nil }
        let owned = windowInfos.filter {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid
        }
        guard let top = owned.first,
              let bounds = top[kCGWindowBounds as String] as? [String: CGFloat],
              let x = bounds["X"], let y = bounds["Y"],
              let w = bounds["Width"], let h = bounds["Height"]
        else { return nil }
        // CGWindow uses top-left origin on the primary display; flip to NS bottom-left.
        let nsY = primary.maxY - (y + h)
        return NSRect(x: x, y: nsY, width: w, height: h)
    }

    /// Wrapper used in tests so we can swap `NSScreen` for a value type.
    struct ScreenFrame {
        let frame: NSRect
        let screen: NSScreen?

        init(frame: NSRect, screen: NSScreen? = nil) {
            self.frame = frame
            self.screen = screen
        }
    }
}

@MainActor
private func defaultWindowList() -> [[String: Any]] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    return (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
}
