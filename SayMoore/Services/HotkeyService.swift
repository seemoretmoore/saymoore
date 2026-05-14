@preconcurrency import AppKit
@preconcurrency import CoreGraphics
import Carbon.HIToolbox

@MainActor
final class HotkeyService {
    var onToggle: ((String?) -> Void)?
    var onCancel: (() -> Void)?
    var isRecording: () -> Bool = { false }

    private let capturer: BundleIDCapturer
    private var recognizer = HotkeyRecognizer()
    private var pendingBundleID: String?
    private var lastFlags: CGEventFlags = []

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(
        provider: WorkspaceProvider? = nil,
        ownBundleID: String = "com.seemoretmoore.saymoore"
    ) {
        let p: WorkspaceProvider = provider ?? NSWorkspaceProvider()
        self.capturer = BundleIDCapturer(provider: p, ownBundleID: ownBundleID)
    }

    func start() {
        guard tap == nil else { return }
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)   |
            (1 << CGEventType.flagsChanged.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: HotkeyService_callback,
            userInfo: refcon
        ) else {
            Log.hotkey.error("CGEvent.tapCreate failed (Input Monitoring not granted?)")
            return
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = src
        Log.hotkey.info("HotkeyService started")
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    // B1: helper — wipes stale state and re-enables the tap after a system disable.
    func resetAfterTapDisable() {
        lastFlags = []
        recognizer = HotkeyRecognizer()
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            resetAfterTapDisable()
            return Unmanaged.passUnretained(event)
        }

        // B2: pass through our own synthesized Cmd-V events without processing.
        if event.getIntegerValueField(.eventSourceUserData) == 0x5359 {
            return Unmanaged.passUnretained(event)
        }

        let now = ProcessInfo.processInfo.systemUptime
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))

        if type == .keyDown && keyCode == kVK_Escape && isRecording() {
            onCancel?()
            return nil
        }

        // B3: modifier virtual key codes (kVK_Command=0x37, kVK_Shift=0x38, kVK_Option=0x3A, kVK_Control=0x3B)
        let modifierKeyCodes: Set<Int> = [0x37, 0x38, 0x3A, 0x3B]

        switch type {
        case .flagsChanged:
            let flags = event.flags
            let wasCtrl = lastFlags.contains(.maskControl)
            let isCtrl  = flags.contains(.maskControl)
            lastFlags = flags
            if isCtrl && !wasCtrl {
                emit(.ctrlDown(at: now))
            } else if !isCtrl && wasCtrl {
                emit(.ctrlUp(at: now))
            } else {
                emit(.otherKey(at: now))
            }

        case .keyDown:
            // B3: only emit .otherKey (which clears pendingBundleID) for real character keys.
            if !modifierKeyCodes.contains(keyCode) {
                emit(.otherKey(at: now))
            }

        case .keyUp:
            break

        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private func emit(_ ev: HotkeyEvent) {
        if case .ctrlDown = ev, pendingBundleID == nil {
            pendingBundleID = capturer.capture()
            Log.hotkey.debug("ctrl-down: captured bundleID=\(self.pendingBundleID ?? "nil", privacy: .public)")
        }
        let out = recognizer.process(ev)
        if case .otherKey = ev {
            pendingBundleID = nil
        }
        if out == .toggle {
            let id = pendingBundleID
            pendingBundleID = nil
            Log.hotkey.info("Ctrl-Ctrl toggle (bundleID=\(id ?? "nil", privacy: .public))")
            onToggle?(id)
        }
    }
}

private func HotkeyService_callback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let service = Unmanaged<HotkeyService>.fromOpaque(refcon).takeUnretainedValue()
    return MainActor.assumeIsolated {
        service.handle(type: type, event: event)
    }
}
