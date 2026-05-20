# Slice 10 — First-Run Permissions Wizard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a blocking 4-step SwiftUI wizard before model download on any launch where Microphone, Accessibility, or Input Monitoring is not granted; Notifications step is skippable.

**Architecture:** `PermissionChecker` protocol + `LivePermissionChecker` provides TCC-isolated status reads and prompt triggers. `PermissionsViewModel` (@MainActor ObservableObject) drives the `PermissionsWizardView` (SwiftUI). `PermissionsWizardWindow` (NSWindow host) mirrors `ModelDownloadWindow`'s `async present()` / `CheckedContinuation` pattern. AppDelegate calls `permissionsWizardIfNeeded()` before `bootstrapModelThenStart()`.

**Tech Stack:** Swift 5.10, strict concurrency, AVFoundation, IOKit.hid, ApplicationServices, UserNotifications, SwiftUI + NSHostingView, XCTest

---

## File Map

| Action | Path | Responsibility |
|---|---|---|
| Create | `SayMoore/Services/PermissionChecker.swift` | `PermissionStatus`, `PermissionStatuses`, `PermissionChecker` protocol, `LivePermissionChecker` |
| Create | `SayMoore/App/PermissionsViewModel.swift` | `@MainActor ObservableObject`; drives step logic; testable via mock |
| Create | `SayMoore/UI/PermissionsWizardView.swift` | SwiftUI 4-step wizard + `PermissionRow` subview |
| Create | `SayMoore/UI/PermissionsWizardWindow.swift` | NSWindow host; `async present()`; NSWindowDelegate re-check |
| Create | `SayMooreTests/PermissionsViewModelTests.swift` | All unit tests |
| Modify | `SayMoore/App/AppDelegate.swift` | Add `permissionsWindow` property + `permissionsWizardIfNeeded()` + call before bootstrap |

---

## Task 1: PermissionStatus types, PermissionStatuses struct, and PermissionChecker protocol

**Files:**
- Create: `SayMoore/Services/PermissionChecker.swift`

- [ ] **Step 1: Create the file with types and protocol**

```swift
// SayMoore/Services/PermissionChecker.swift
import AVFoundation
import IOKit.hid
import ApplicationServices
import UserNotifications

enum PermissionStatus: Equatable {
    case granted
    case notDetermined
    case denied
}

struct PermissionStatuses: Equatable {
    var microphone: PermissionStatus
    var accessibility: PermissionStatus
    var inputMonitoring: PermissionStatus
    var notifications: PermissionStatus

    var allRequiredGranted: Bool {
        microphone == .granted && accessibility == .granted && inputMonitoring == .granted
    }

    var currentStep: Int {
        if microphone != .granted { return 1 }
        if accessibility != .granted { return 2 }
        if inputMonitoring != .granted { return 3 }
        if notifications != .granted { return 4 }
        return 5
    }

    static let initial = PermissionStatuses(
        microphone: .notDetermined,
        accessibility: .notDetermined,
        inputMonitoring: .notDetermined,
        notifications: .notDetermined
    )
}

protocol PermissionChecker: AnyObject {
    func microphoneStatus() -> PermissionStatus
    func accessibilityStatus() -> PermissionStatus
    func inputMonitoringStatus() -> PermissionStatus
    func notificationsStatus() async -> PermissionStatus
    func requestMicrophoneAccess() async
    func requestNotificationsAccess() async
}

final class LivePermissionChecker: PermissionChecker {
    func microphoneStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    func accessibilityStatus() -> PermissionStatus {
        AXIsProcessTrusted() ? .granted : .notDetermined
    }

    func inputMonitoringStatus() -> PermissionStatus {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied: return .denied
        default: return .notDetermined
        }
    }

    func notificationsStatus() async -> PermissionStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .granted
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    func requestMicrophoneAccess() async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
    }

    func requestNotificationsAccess() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
    }
}
```

- [ ] **Step 2: Build to confirm no compile errors**

```bash
xcodebuild build -scheme SayMoore -destination 'platform=macOS' 2>&1 | grep -E 'error:|BUILD'
```

Expected: `BUILD SUCCEEDED` with no `error:` lines.

- [ ] **Step 3: Commit**

```bash
git add SayMoore/Services/PermissionChecker.swift
git commit -m "feat(slice-10): PermissionStatus types + PermissionChecker protocol + LivePermissionChecker"
```

---

## Task 2: PermissionStatuses pure-logic tests

**Files:**
- Create: `SayMooreTests/PermissionsViewModelTests.swift`

- [ ] **Step 1: Write failing tests for PermissionStatuses**

```swift
// SayMooreTests/PermissionsViewModelTests.swift
import XCTest
@testable import SayMoore

// MARK: - MockPermissionChecker

final class MockPermissionChecker: PermissionChecker {
    var micStatus: PermissionStatus = .notDetermined
    var accessStatus: PermissionStatus = .notDetermined
    var inputStatus: PermissionStatus = .notDetermined
    var notifStatus: PermissionStatus = .notDetermined

    var micRequestCount = 0
    var notifRequestCount = 0

    func microphoneStatus() -> PermissionStatus { micStatus }
    func accessibilityStatus() -> PermissionStatus { accessStatus }
    func inputMonitoringStatus() -> PermissionStatus { inputStatus }
    func notificationsStatus() async -> PermissionStatus { notifStatus }
    func requestMicrophoneAccess() async { micRequestCount += 1 }
    func requestNotificationsAccess() async { notifRequestCount += 1 }
}

// MARK: - PermissionStatuses tests

@MainActor
final class PermissionStatusesTests: XCTestCase {

    func test_allRequiredGranted_whenAllThreeGranted() {
        let s = PermissionStatuses(microphone: .granted, accessibility: .granted,
                                   inputMonitoring: .granted, notifications: .notDetermined)
        XCTAssertTrue(s.allRequiredGranted)
    }

    func test_allRequiredGranted_false_whenMicMissing() {
        let s = PermissionStatuses(microphone: .notDetermined, accessibility: .granted,
                                   inputMonitoring: .granted, notifications: .granted)
        XCTAssertFalse(s.allRequiredGranted)
    }

    func test_allRequiredGranted_false_whenAccessibilityMissing() {
        let s = PermissionStatuses(microphone: .granted, accessibility: .notDetermined,
                                   inputMonitoring: .granted, notifications: .granted)
        XCTAssertFalse(s.allRequiredGranted)
    }

    func test_allRequiredGranted_false_whenInputMonitoringMissing() {
        let s = PermissionStatuses(microphone: .granted, accessibility: .granted,
                                   inputMonitoring: .notDetermined, notifications: .granted)
        XCTAssertFalse(s.allRequiredGranted)
    }

    func test_allRequiredGranted_true_whenNotificationsDenied() {
        let s = PermissionStatuses(microphone: .granted, accessibility: .granted,
                                   inputMonitoring: .granted, notifications: .denied)
        XCTAssertTrue(s.allRequiredGranted)
    }

    func test_currentStep_one_whenMicNotGranted() {
        let s = PermissionStatuses(microphone: .notDetermined, accessibility: .granted,
                                   inputMonitoring: .granted, notifications: .granted)
        XCTAssertEqual(s.currentStep, 1)
    }

    func test_currentStep_two_whenMicGrantedAccessibilityNotGranted() {
        let s = PermissionStatuses(microphone: .granted, accessibility: .notDetermined,
                                   inputMonitoring: .granted, notifications: .granted)
        XCTAssertEqual(s.currentStep, 2)
    }

    func test_currentStep_three_whenMicAndAccessibilityGrantedInputMonitoringNotGranted() {
        let s = PermissionStatuses(microphone: .granted, accessibility: .granted,
                                   inputMonitoring: .notDetermined, notifications: .granted)
        XCTAssertEqual(s.currentStep, 3)
    }

    func test_currentStep_four_whenAllRequiredGrantedNotificationsMissing() {
        let s = PermissionStatuses(microphone: .granted, accessibility: .granted,
                                   inputMonitoring: .granted, notifications: .notDetermined)
        XCTAssertEqual(s.currentStep, 4)
    }

    func test_currentStep_five_whenAllGranted() {
        let s = PermissionStatuses(microphone: .granted, accessibility: .granted,
                                   inputMonitoring: .granted, notifications: .granted)
        XCTAssertEqual(s.currentStep, 5)
    }
}
```

- [ ] **Step 2: Run tests to confirm they fail (PermissionsViewModel doesn't exist yet)**

```bash
xcodebuild test -scheme SayMoore -destination 'platform=macOS' \
  -only-testing:SayMooreTests/PermissionStatusesTests 2>&1 | tail -10
```

Expected: Tests pass (these are pure struct tests on already-defined types). If any test fails, the type definition in Task 1 has a bug — fix it before continuing.

- [ ] **Step 3: Commit**

```bash
git add SayMooreTests/PermissionsViewModelTests.swift
git commit -m "test(slice-10): PermissionStatuses pure-logic tests"
```

---

## Task 3: PermissionsViewModel — write tests first

**Files:**
- Modify: `SayMooreTests/PermissionsViewModelTests.swift` (add PermissionsViewModel test class)

- [ ] **Step 1: Append PermissionsViewModel tests to the test file**

Add this after the closing brace of `PermissionStatusesTests`:

```swift
// MARK: - PermissionsViewModel tests

@MainActor
final class PermissionsViewModelTests: XCTestCase {

    func test_recheck_requestsMicrophoneOnce_whenNotDetermined() async {
        let checker = MockPermissionChecker()
        checker.micStatus = .notDetermined
        let vm = PermissionsViewModel(checker: checker)
        await vm.recheck()
        await vm.recheck()
        XCTAssertEqual(checker.micRequestCount, 1)
    }

    func test_recheck_doesNotRequestMicrophone_whenAlreadyGranted() async {
        let checker = MockPermissionChecker()
        checker.micStatus = .granted
        checker.accessStatus = .granted
        checker.inputStatus = .granted
        checker.notifStatus = .granted
        let vm = PermissionsViewModel(checker: checker)
        await vm.recheck()
        XCTAssertEqual(checker.micRequestCount, 0)
    }

    func test_recheck_updatesStatuses_afterCheck() async {
        let checker = MockPermissionChecker()
        checker.micStatus = .granted
        checker.accessStatus = .denied
        checker.inputStatus = .notDetermined
        checker.notifStatus = .notDetermined
        let vm = PermissionsViewModel(checker: checker)
        await vm.recheck()
        XCTAssertEqual(vm.statuses.microphone, .granted)
        XCTAssertEqual(vm.statuses.accessibility, .denied)
        XCTAssertEqual(vm.statuses.inputMonitoring, .notDetermined)
    }

    func test_recheck_firesOnAllGranted_whenAllRequiredGranted() async {
        let checker = MockPermissionChecker()
        checker.micStatus = .granted
        checker.accessStatus = .granted
        checker.inputStatus = .granted
        checker.notifStatus = .granted
        let vm = PermissionsViewModel(checker: checker)
        var fired = false
        vm.onAllGranted = { fired = true }
        await vm.recheck()
        XCTAssertTrue(fired)
    }

    func test_recheck_doesNotFireOnAllGranted_whenInputMonitoringMissing() async {
        let checker = MockPermissionChecker()
        checker.micStatus = .granted
        checker.accessStatus = .granted
        checker.inputStatus = .notDetermined
        checker.notifStatus = .granted
        let vm = PermissionsViewModel(checker: checker)
        var fired = false
        vm.onAllGranted = { fired = true }
        await vm.recheck()
        XCTAssertFalse(fired)
    }

    func test_recheck_requestsNotificationsOnce_whenOnStep4() async {
        let checker = MockPermissionChecker()
        checker.micStatus = .granted
        checker.accessStatus = .granted
        checker.inputStatus = .granted
        checker.notifStatus = .notDetermined
        let vm = PermissionsViewModel(checker: checker)
        await vm.recheck()
        await vm.recheck()
        XCTAssertEqual(checker.notifRequestCount, 1)
    }

    func test_recheck_doesNotRequestNotifications_whenRequiredPermissionsMissing() async {
        let checker = MockPermissionChecker()
        checker.micStatus = .granted
        checker.accessStatus = .granted
        checker.inputStatus = .notDetermined   // still on step 3
        checker.notifStatus = .notDetermined
        let vm = PermissionsViewModel(checker: checker)
        await vm.recheck()
        XCTAssertEqual(checker.notifRequestCount, 0)
    }

    func test_skipNotifications_firesOnAllGranted_whenRequiredGranted() async {
        let checker = MockPermissionChecker()
        checker.micStatus = .granted
        checker.accessStatus = .granted
        checker.inputStatus = .granted
        checker.notifStatus = .notDetermined
        let vm = PermissionsViewModel(checker: checker)
        await vm.recheck()   // populates statuses
        var fired = false
        vm.onAllGranted = { fired = true }
        vm.skipNotifications()
        XCTAssertTrue(fired)
    }

    func test_skipNotifications_doesNotFire_whenRequiredPermissionsMissing() async {
        let checker = MockPermissionChecker()
        checker.micStatus = .notDetermined
        let vm = PermissionsViewModel(checker: checker)
        var fired = false
        vm.onAllGranted = { fired = true }
        vm.skipNotifications()
        XCTAssertFalse(fired)
    }
}
```

- [ ] **Step 2: Run tests to confirm they fail (PermissionsViewModel not yet defined)**

```bash
xcodebuild test -scheme SayMoore -destination 'platform=macOS' \
  -only-testing:SayMooreTests/PermissionsViewModelTests 2>&1 | grep -E 'error:|FAILED|passed|failed' | head -20
```

Expected: Compile error — `PermissionsViewModel` not found.

---

## Task 4: PermissionsViewModel implementation

**Files:**
- Create: `SayMoore/App/PermissionsViewModel.swift`

- [ ] **Step 1: Create PermissionsViewModel**

```swift
// SayMoore/App/PermissionsViewModel.swift
import Foundation

@MainActor
final class PermissionsViewModel: ObservableObject {
    @Published private(set) var statuses: PermissionStatuses = .initial

    let checker: any PermissionChecker
    var onAllGranted: () -> Void = {}

    private var micRequestedOnce = false
    private var notifRequestedOnce = false

    init(checker: any PermissionChecker) {
        self.checker = checker
    }

    func recheck() async {
        if !micRequestedOnce && checker.microphoneStatus() == .notDetermined {
            micRequestedOnce = true
            await checker.requestMicrophoneAccess()
        }

        let mic = checker.microphoneStatus()
        let access = checker.accessibilityStatus()
        let input = checker.inputMonitoringStatus()
        var notif = await checker.notificationsStatus()

        if mic == .granted && access == .granted && input == .granted &&
           notif == .notDetermined && !notifRequestedOnce {
            notifRequestedOnce = true
            await checker.requestNotificationsAccess()
            notif = await checker.notificationsStatus()
        }

        statuses = PermissionStatuses(
            microphone: mic,
            accessibility: access,
            inputMonitoring: input,
            notifications: notif
        )

        if statuses.allRequiredGranted {
            onAllGranted()
        }
    }

    func skipNotifications() {
        if statuses.allRequiredGranted {
            onAllGranted()
        }
    }
}
```

- [ ] **Step 2: Run all PermissionsViewModel tests — must pass**

```bash
xcodebuild test -scheme SayMoore -destination 'platform=macOS' \
  -only-testing:SayMooreTests/PermissionsViewModelTests 2>&1 | grep -E 'Test.*passed|Test.*failed|BUILD'
```

Expected: All 8 PermissionsViewModelTests pass, all 10 PermissionStatusesTests pass.

- [ ] **Step 3: Commit**

```bash
git add SayMoore/App/PermissionsViewModel.swift SayMooreTests/PermissionsViewModelTests.swift
git commit -m "feat(slice-10): PermissionsViewModel with recheck + skipNotifications"
```

---

## Task 5: PermissionsWizardView

**Files:**
- Create: `SayMoore/UI/PermissionsWizardView.swift`

- [ ] **Step 1: Create the SwiftUI view**

```swift
// SayMoore/UI/PermissionsWizardView.swift
import SwiftUI
import AppKit

struct PermissionsWizardView: View {
    @ObservedObject var viewModel: PermissionsViewModel
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Grant Permissions")
                .font(.title2)
                .bold()
                .padding(.bottom, 4)
            Text("SayMoore needs these permissions to work.")
                .foregroundStyle(.secondary)
                .padding(.bottom, 20)

            VStack(alignment: .leading, spacing: 12) {
                PermissionRow(
                    label: "Microphone",
                    reason: "To capture your voice for transcription.",
                    status: viewModel.statuses.microphone,
                    deeplink: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
                    isActive: viewModel.statuses.currentStep == 1,
                    isSkippable: false,
                    onManual: { Task { await viewModel.recheck() } },
                    onSkip: nil
                )
                PermissionRow(
                    label: "Accessibility",
                    reason: "To detect your Ctrl+Ctrl hotkey.",
                    status: viewModel.statuses.accessibility,
                    deeplink: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
                    isActive: viewModel.statuses.currentStep == 2,
                    isSkippable: false,
                    onManual: { Task { await viewModel.recheck() } },
                    onSkip: nil
                )
                PermissionRow(
                    label: "Input Monitoring",
                    reason: "To listen for your keyboard hotkey globally.",
                    status: viewModel.statuses.inputMonitoring,
                    deeplink: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
                    isActive: viewModel.statuses.currentStep == 3,
                    isSkippable: false,
                    onManual: { Task { await viewModel.recheck() } },
                    onSkip: nil
                )
                PermissionRow(
                    label: "Notifications (optional)",
                    reason: "To show transcription status and error alerts.",
                    status: viewModel.statuses.notifications,
                    deeplink: "x-apple.systempreferences:com.apple.preference.notifications",
                    isActive: viewModel.statuses.currentStep == 4,
                    isSkippable: true,
                    onManual: { Task { await viewModel.recheck() } },
                    onSkip: { viewModel.skipNotifications() }
                )
            }

            Spacer(minLength: 20)

            HStack {
                Spacer()
                Button("Quit", action: onQuit)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 420, alignment: .leading)
    }
}

private struct PermissionRow: View {
    let label: String
    let reason: String
    let status: PermissionStatus
    let deeplink: String
    let isActive: Bool
    let isSkippable: Bool
    let onManual: () -> Void
    let onSkip: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .fontWeight(isActive ? .semibold : .regular)
                    .foregroundStyle(isActive ? .primary : (status == .granted ? .secondary : .primary))

                if isActive {
                    Text(status == .denied
                        ? "You previously denied this. Open Settings to re-enable it."
                        : reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Button("Open Settings") {
                            if let url = URL(string: deeplink) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .keyboardShortcut(.defaultAction)

                        if isSkippable {
                            Button("Skip for now") { onSkip?() }
                        } else {
                            Button("Check Again") { onManual() }
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .granted:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .imageScale(.large)
        case .denied:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .imageScale(.large)
        case .notDetermined:
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
                .imageScale(.large)
        }
    }
}
```

- [ ] **Step 2: Build to confirm no compile errors**

```bash
xcodebuild build -scheme SayMoore -destination 'platform=macOS' 2>&1 | grep -E 'error:|BUILD'
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add SayMoore/UI/PermissionsWizardView.swift
git commit -m "feat(slice-10): PermissionsWizardView SwiftUI 4-step wizard"
```

---

## Task 6: PermissionsWizardWindow

**Files:**
- Create: `SayMoore/UI/PermissionsWizardWindow.swift`

- [ ] **Step 1: Create the window host**

```swift
// SayMoore/UI/PermissionsWizardWindow.swift
import AppKit
import SwiftUI

@MainActor
final class PermissionsWizardWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let viewModel: PermissionsViewModel
    private var continuation: CheckedContinuation<Void, Never>?
    private var recheckTask: Task<Void, Never>?

    init(checker: any PermissionChecker) {
        self.viewModel = PermissionsViewModel(checker: checker)
        self.window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "SayMoore Setup"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
        super.init()
        window.delegate = self
    }

    /// Suspends until all required permissions are granted (Notifications skippable).
    func present() async {
        viewModel.onAllGranted = { [weak self] in self?.finish() }
        let view = PermissionsWizardView(
            viewModel: viewModel,
            onQuit: { NSApp.terminate(nil) }
        )
        let hostingView = NSHostingView(rootView: view)
        window.contentView = hostingView
        window.setContentSize(hostingView.fittingSize)
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        // Continuation is set before windowDidBecomeKey fires on the next run-loop tick.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.continuation = cont
        }
    }

    func close() {
        window.orderOut(nil)
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        recheckTask?.cancel()
        recheckTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.viewModel.recheck()
            // TCC can lag ~500ms after user toggles a switch in Settings.
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self.viewModel.recheck()
        }
    }

    private func finish() {
        continuation?.resume()
        continuation = nil
    }
}
```

- [ ] **Step 2: Build to confirm no compile errors**

```bash
xcodebuild build -scheme SayMoore -destination 'platform=macOS' 2>&1 | grep -E 'error:|BUILD'
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add SayMoore/UI/PermissionsWizardWindow.swift
git commit -m "feat(slice-10): PermissionsWizardWindow NSWindow host with async present"
```

---

## Task 7: AppDelegate integration

**Files:**
- Modify: `SayMoore/App/AppDelegate.swift`

- [ ] **Step 1: Add `permissionsWindow` property near line 20**

After the existing line:
```swift
    private var bootstrapWindow: ModelDownloadWindow?
```

Add:
```swift
    private var permissionsWindow: PermissionsWizardWindow?
```

- [ ] **Step 2: Add `permissionsWizardIfNeeded()` method near `bootstrapModelThenStart()`**

Add this private method immediately before `bootstrapModelThenStart()`:

```swift
    private func permissionsWizardIfNeeded() async {
        let checker = LivePermissionChecker()
        guard !(checker.microphoneStatus() == .granted &&
                checker.accessibilityStatus() == .granted &&
                checker.inputMonitoringStatus() == .granted) else { return }
        let win = PermissionsWizardWindow(checker: checker)
        permissionsWindow = win
        await win.present()
        win.close()
        permissionsWindow = nil
    }
```

- [ ] **Step 3: Prepend `permissionsWizardIfNeeded()` to the bootstrap Task**

Find the existing Task block (around line 66):
```swift
        Task {
            await bootstrapModelThenStart()
        }
```

Replace with:
```swift
        Task {
            await permissionsWizardIfNeeded()
            await bootstrapModelThenStart()
        }
```

- [ ] **Step 4: Build to confirm no compile errors**

```bash
xcodebuild build -scheme SayMoore -destination 'platform=macOS' 2>&1 | grep -E 'error:|BUILD'
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Run full test suite to confirm no regressions**

```bash
xcodebuild test -scheme SayMoore -destination 'platform=macOS' 2>&1 | grep -E 'Test.*passed|Test.*failed|BUILD' | tail -5
```

Expected: All existing tests pass plus new PermissionsViewModelTests.

- [ ] **Step 6: Commit**

```bash
git add SayMoore/App/AppDelegate.swift
git commit -m "feat(slice-10): wire permissionsWizardIfNeeded into AppDelegate launch sequence"
```

---

## Task 8: Manual test doc

**Files:**
- Create: `docs/manual-tests/slice-10.md`

- [ ] **Step 1: Write the manual test matrix**

```markdown
# Manual Tests — Slice 10: Permissions Wizard

## Prerequisites
- A second macOS user account (or revoke all permissions for the main account via Privacy & Security)
- App built and installed at /Applications/SayMoore.app

## Test cases

### MT-10-1: Fresh account — full walkthrough
1. Log in as test user (or revoke all SayMoore permissions)
2. Launch SayMoore
3. **Expected:** Wizard appears before any other window; step 1 (Microphone) is active
4. Click "Open Settings" → System Settings > Privacy & Security > Microphone opens
5. Toggle SayMoore on
6. Return to wizard
7. **Expected:** Step 1 shows green checkmark; step 2 (Accessibility) is now active
8. Click "Open Settings" → Accessibility pane opens
9. Add/toggle SayMoore
10. Return → step 3 (Input Monitoring) active
11. Repeat for Input Monitoring
12. **Expected:** Step 4 (Notifications optional) becomes active
13. Click "Open Settings" → Notifications pane opens
14. Grant or skip
15. **Expected:** Wizard closes; model download begins

### MT-10-2: "I opened Settings myself" button
1. Revoke all permissions, launch SayMoore
2. On step 1, open Settings manually (not via button)
3. Grant Microphone in Settings
4. Return to wizard; click "I opened Settings myself"
5. **Expected:** Step 1 shows green checkmark; wizard advances to step 2

### MT-10-3: Window focus re-check
1. Revoke all permissions, launch SayMoore
2. On step 2 (Accessibility), open Settings manually
3. Grant Accessibility in Settings
4. Click back to the wizard window
5. **Expected:** Without pressing any button, wizard auto-advances to step 3 within ~1.5s

### MT-10-4: Skip Notifications
1. Complete steps 1-3; step 4 appears
2. Click "Skip for now"
3. **Expected:** Wizard closes; model download begins

### MT-10-5: Notifications step re-appears on next launch
1. After MT-10-4 (notifications skipped), quit and relaunch
2. **Expected:** Wizard re-appears at step 4 (Notifications) since steps 1-3 are granted

### MT-10-6: Revoke mid-session permission, relaunch
1. Complete wizard fully; use app briefly
2. In System Settings, revoke Accessibility
3. Quit and relaunch SayMoore
4. **Expected:** Wizard re-appears at step 2 (Accessibility)

### MT-10-7: All permissions already granted
1. Complete wizard; quit; relaunch
2. **Expected:** Wizard does NOT appear; app goes directly to model download (or pipeline if model already downloaded)

### MT-10-8: Quit button
1. Revoke all permissions; launch SayMoore
2. Click "Quit" in the wizard
3. **Expected:** App terminates cleanly
```

- [ ] **Step 2: Commit**

```bash
git add docs/manual-tests/slice-10.md
git commit -m "docs(slice-10): manual test matrix for permissions wizard"
```

---

## Self-Review Checklist

- [x] **Spec coverage:** All PRD deliverables covered — 4-step wizard, deeplinks, fallback button, auto-advance on focus return, blocks app entry until Mic+Accessibility+Input Monitoring granted, Notifications skippable, revocation-at-launch re-surfaces wizard.
- [x] **No placeholders:** All steps have complete code or exact commands.
- [x] **Type consistency:** `PermissionStatus`, `PermissionStatuses`, `PermissionChecker`, `LivePermissionChecker`, `PermissionsViewModel`, `PermissionsWizardView`, `PermissionsWizardWindow` used consistently throughout.
- [x] **`permissionsWizardIfNeeded` pre-check logic:** `guard !(mic == .granted && access == .granted && input == .granted) else { return }` correctly skips wizard only when all three required permissions are already granted.
- [x] **Continuation safety:** `windowDidBecomeKey` fires on the next run-loop tick after `makeKeyAndOrderFront`, which is after `withCheckedContinuation` sets `self.continuation` — no nil continuation race.
