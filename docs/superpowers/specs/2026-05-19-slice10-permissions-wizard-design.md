# Slice 10 — First-Run Permissions Wizard Design

**Date:** 2026-05-19  
**Status:** Approved

## Goal

Walk new users through granting Mic, Accessibility, Input Monitoring, and Notifications before the app becomes usable. Re-surface the wizard on any subsequent launch where required permissions are missing.

---

## Architecture

### Startup sequence

```
AppDelegate.applicationDidFinishLaunching
  └─► permissionsWizardIfNeeded()     ← NEW, async, blocks
        └─► PermissionChecker.allStatuses()
              if any required missing:
                PermissionsWizardWindow.present() async  ← awaits all-required granted
  └─► bootstrapModelThenStart()       ← unchanged
  └─► startPipeline()                 ← unchanged
```

Permissions gate runs **before** model download. No "first launch" flag — the check runs every launch; wizard only shows if something is missing.

### New files

| File | Role |
|---|---|
| `SayMoore/Services/PermissionChecker.swift` | Protocol + live impl + mock |
| `SayMoore/UI/PermissionsWizardWindow.swift` | `NSWindow` host; `async present()` awaits all-required granted |
| `SayMoore/UI/PermissionsWizardView.swift` | SwiftUI 4-step wizard UI |

### Modified files

| File | Change |
|---|---|
| `SayMoore/App/AppDelegate.swift` | Add `permissionsWizardIfNeeded()` call before `bootstrapModelThenStart()` |

---

## PermissionChecker Protocol

```swift
protocol PermissionChecker {
    func microphoneStatus() -> PermissionStatus
    func accessibilityStatus() -> PermissionStatus
    func inputMonitoringStatus() -> PermissionStatus
    func notificationsStatus() async -> PermissionStatus
}

enum PermissionStatus { case granted, denied, notDetermined }
```

**Live implementation details:**

- **Microphone:** `AVCaptureDevice.authorizationStatus(for: .audio)`. On first check when `.notDetermined`, calls `AVCaptureDevice.requestAccess(for: .audio)` to trigger the system prompt. Subsequent reads use the cached status.
- **Accessibility:** `AXIsProcessTrusted(options: [kAXTrustedCheckOptionPrompt: false] as CFDictionary)` — never triggers the system prompt on status reads.
- **Input Monitoring:** `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)` — same no-prompt pattern.
- **Notifications:** `UNUserNotificationCenter.current().getNotificationSettings()` for status; `requestAuthorization(options:)` called once when step 4 is reached and status is `.notDetermined`.

---

## PermissionsWizardWindow

Mirrors `ModelDownloadWindow` exactly:

- `NSWindow`: 420×320, `.titled`, no `.closable`, `.floating` level, centered
- `isReleasedWhenClosed = false`
- `NSHostingView` wrapping `PermissionsWizardView`
- `async present()` suspends via `CheckedContinuation<Void, Never>`
- Implements `NSWindowDelegate.windowDidBecomeKey` → calls `viewModel.recheck()`
- `finish()` cancels observation and resumes continuation
- Quit button calls `NSApp.terminate(nil)`

---

## PermissionsViewModel

`@MainActor ObservableObject` owned by the window:

```swift
@MainActor
final class PermissionsViewModel: ObservableObject {
    @Published private(set) var statuses: PermissionStatuses
    let checker: PermissionChecker

    func recheck() async { ... }  // updates statuses, calls finish() if all required granted
}

struct PermissionStatuses {
    var microphone: PermissionStatus
    var accessibility: PermissionStatus
    var inputMonitoring: PermissionStatus
    var notifications: PermissionStatus

    var allRequiredGranted: Bool {
        microphone == .granted && accessibility == .granted && inputMonitoring == .granted
    }
}
```

---

## PermissionsWizardView — UX Flow

Single SwiftUI view, step-driven. Steps are sequential — each step is shown only when all previous required permissions are granted.

**Step order:**

| Step | Permission | Required | Deeplink |
|---|---|---|---|
| 1 | Microphone | Yes | `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone` |
| 2 | Accessibility | Yes | `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility` |
| 3 | Input Monitoring | Yes | `x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent` |
| 4 | Notifications | No | `x-apple.systempreferences:com.apple.preference.notifications` |

**Each required step shows:**
- Permission name + one-line reason
- "Open Settings" button (fires deeplink via `NSWorkspace.shared.open`)
- "I opened Settings myself" button (calls `viewModel.recheck()` immediately)
- Status indicator: spinner/waiting or green checkmark

**Step 4 (Notifications) shows:**
- Same layout but "Skip for now" instead of "I opened Settings myself"
- Skipping does not record state; wizard re-shows step 4 on next launch if still not granted

**Auto-advance:** On each `recheck()`, the view computes the current step from statuses and redraws. If `allRequiredGranted`, the window calls `finish()` regardless of notification status.

---

## Re-check Mechanism

Two triggers on every window focus return:

1. **Immediate:** `windowDidBecomeKey` → `viewModel.recheck()`
2. **Delayed:** `DispatchQueue.main.asyncAfter(deadline: .now() + 1.0)` → `viewModel.recheck()`

The 1-second delayed re-check handles TCC propagation lag (~500ms after the user toggles a switch in Settings).

"I opened Settings myself" / "Skip for now" buttons call `viewModel.recheck()` directly (same path as focus return).

---

## Error Handling & Edge Cases

| Scenario | Behavior |
|---|---|
| Deeplink fails silently | "I opened Settings myself" button always visible — not a fallback, always shown alongside "Open Settings" |
| User closes Settings without granting | Re-check on next focus return; wizard stays on current step |
| User force-quits | Next launch re-enters wizard (no state persisted) |
| Notification step skipped every time | Wizard shows step 4 again each launch; app runs without notifications |
| TCC propagation lag | 1s delayed re-check catches grants that the immediate check missed |
| Mic prompt timing | `requestAccess` called when wizard reaches step 1 — prompt appears in context |

---

## Testing

**Unit tests** (`SayMooreTests/`):

- `MockPermissionChecker` with settable statuses per permission
- `PermissionsViewModel` tests: all-granted skips wizard, partial-granted shows correct step, notifications-only-missing still completes, recheck advances step correctly
- `PermissionStatus` mapping from AVFoundation/IOKit/UNNotification statuses

**Manual test matrix** (to be written as `docs/manual-tests/slice-10.md`):

- Fresh user account: wizard appears, all 4 steps shown in order
- Each deeplink opens correct Settings pane
- Each "I opened Settings myself" re-checks and advances
- Revoke each permission after granting: re-launch shows wizard at that step
- Skip notifications: app runs, step 4 re-appears on next launch
- Grant all: wizard closes, model download begins
