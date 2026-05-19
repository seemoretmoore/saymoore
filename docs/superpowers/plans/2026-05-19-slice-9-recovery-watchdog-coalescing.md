# Slice 9 — Recovery handlers + watchdog + notification coalescing — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every failure path produces a clear, deduplicated notification and either recovers or surfaces actionable fix instructions. No notification storms; persistent error conditions show in the menu bar.

**Architecture:**
- New `NotificationCoordinator` wraps `NotificationCenterAdapter` and enforces a 60-second cooldown per error class. It also exposes a `persistentBadge` property that `MenuBarController` observes.
- `PipelineCoordinator` gains a 30 s global watchdog that fires `.watchdogTimeout` if a pipeline run never reaches `.idle`.
- `AudioRecorder` listens for `AVAudioEngine.configurationChangeNotification`; when fired mid-recording, it aborts the engine and surfaces `.audioEngineFailed` via a new callback handled by `PipelineCoordinator`.
- `AppDelegate.applicationShouldTerminate(_:)` blocks Cmd-Q when the pipeline is non-idle (confirm-discard while `.recording`, grace-wait up to 5 s while transcribing/cleaning/pasting).
- Existing per-error notification call sites route through `NotificationCoordinator.shared` instead of `NotificationCenterAdapter.shared`.
- Mic-permission-revoked-mid-session, Ollama cold-spawn, and Model-corrupted re-download share the same notification pipe.
- HistoryStore disk-full is **out of scope** — `HistoryStore.swift` does not yet exist (PRD-listed for later work). Tracked as a Slice 9 follow-up rather than a stub.

**Tech Stack:** Swift / AppKit / AVFoundation / XCTest. macOS-only.

**Bundles:** A (coalescing core), B (watchdog + audio-device + quit), C (mic-revoke + ollama-spawn + model re-download + catalog doc). Each bundle ends in a green build + commit.

---

## Files

**Create:**
- `SayMoore/Services/NotificationCoordinator.swift` — coalescing + badge state
- `SayMoore/Services/MicrophonePermissionMonitor.swift` — polls `AVCaptureDevice.authorizationStatus(for: .audio)` while recording
- `SayMoore/Services/OllamaSupervisor.swift` — best-effort `ollama serve` cold-spawn (Process)
- `docs/error-recovery.md` — error catalog mapping each `SayMooreError` case to user-visible copy + recovery path
- `SayMooreTests/NotificationCoordinatorTests.swift`
- `SayMooreTests/PipelineCoordinatorWatchdogTests.swift`
- `SayMooreTests/AudioRecorderConfigChangeTests.swift`
- `SayMooreTests/OllamaSupervisorTests.swift`
- `SayMooreTests/MicrophonePermissionMonitorTests.swift`
- `docs/manual-tests/slice-9.md`

**Modify:**
- `SayMoore/App/PipelineCoordinator.swift` — add 30 s watchdog timer; wire audio-config-change abort
- `SayMoore/App/AppDelegate.swift` — replace `NotificationCenterAdapter.shared` call sites with `NotificationCoordinator.shared`; install `applicationShouldTerminate(_:)`; wire `MicrophonePermissionMonitor`; wire `OllamaSupervisor` into the existing health-probe block; subscribe `MenuBarController` to the badge
- `SayMoore/Services/AudioRecorder.swift` — observe `AVAudioEngine.configurationChangeNotification`; expose `onDeviceChange: (@MainActor () -> Void)?`
- `SayMoore/UI/MenuBarController.swift` — render a small persistent-error glyph when `NotificationCoordinator` reports a non-nil badge
- `SayMoore/App/ModelBootstrap.swift` — if SHA256 mismatch on load, emit `.modelCorrupted` and offer re-download via existing `ModelDownloadWindow`
- `project.yml` — add new source/test files to targets (the project uses XcodeGen)

---

## Bundle A — NotificationCoordinator (coalescing + badge)

### Task A1: NotificationCoordinator type with cooldown + badge

**Files:**
- Create: `SayMoore/Services/NotificationCoordinator.swift`
- Test: `SayMooreTests/NotificationCoordinatorTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import SayMoore

@MainActor
final class NotificationCoordinatorTests: XCTestCase {
    final class FakeClock {
        var now: ContinuousClock.Instant
        init() { self.now = ContinuousClock.now }
    }
    final class SpySink: NotificationSink, @unchecked Sendable {
        var calls: [(String, String)] = []
        func send(title: String, body: String) { calls.append((title, body)) }
    }

    func test_firstErrorOfClass_isSent() {
        let sink = SpySink()
        let clock = FakeClock()
        let coord = NotificationCoordinator(sink: sink, cooldown: .seconds(60), now: { clock.now })
        coord.notify(.ollamaUnreachable)
        XCTAssertEqual(sink.calls.count, 1)
    }

    func test_repeatWithinCooldown_isCoalesced() {
        let sink = SpySink()
        let clock = FakeClock()
        let coord = NotificationCoordinator(sink: sink, cooldown: .seconds(60), now: { clock.now })
        coord.notify(.ollamaUnreachable)
        clock.now = clock.now.advanced(by: .seconds(30))
        coord.notify(.ollamaUnreachable)
        XCTAssertEqual(sink.calls.count, 1)
    }

    func test_repeatAfterCooldown_isResent() {
        let sink = SpySink()
        let clock = FakeClock()
        let coord = NotificationCoordinator(sink: sink, cooldown: .seconds(60), now: { clock.now })
        coord.notify(.ollamaUnreachable)
        clock.now = clock.now.advanced(by: .seconds(61))
        coord.notify(.ollamaUnreachable)
        XCTAssertEqual(sink.calls.count, 2)
    }

    func test_differentClasses_areIndependent() {
        let sink = SpySink()
        let clock = FakeClock()
        let coord = NotificationCoordinator(sink: sink, cooldown: .seconds(60), now: { clock.now })
        coord.notify(.ollamaUnreachable)
        coord.notify(.micPermissionDenied)
        XCTAssertEqual(sink.calls.count, 2)
    }

    func test_persistentErrors_setBadge_andTransientErrors_dontTouchIt() {
        let sink = SpySink()
        let clock = FakeClock()
        let coord = NotificationCoordinator(sink: sink, cooldown: .seconds(60), now: { clock.now })
        var observed: NotificationCoordinator.Badge? = .init(label: "init")
        coord.onBadgeChange = { observed = $0 }
        coord.notify(.ollamaUnreachable)            // persistent
        XCTAssertEqual(observed?.label, "Ollama down")
        coord.notify(.pasteFocusChanged(captured: nil, current: nil))  // transient
        XCTAssertEqual(observed?.label, "Ollama down")
        coord.clearBadge(for: .ollamaUnreachable)
        XCTAssertNil(observed)
    }
}
```

- [ ] **Step 2: Run tests, verify they fail to compile**

```bash
xcodebuild -project SayMoore.xcodeproj -scheme SayMoore -destination 'platform=macOS' test -only-testing:SayMooreTests/NotificationCoordinatorTests
```
Expected: compile error — `NotificationCoordinator` undefined.

- [ ] **Step 3: Implement NotificationCoordinator**

```swift
import Foundation

protocol NotificationSink: Sendable {
    func send(title: String, body: String)
}

extension NotificationCenterAdapter: NotificationSink {
    func send(title: String, body: String) { notify(title: title, body: body) }
}

@MainActor
final class NotificationCoordinator {
    struct Badge: Equatable {
        let key: ErrorClass
        let label: String
    }

    enum ErrorClass: Hashable {
        case ollamaUnreachable, ollamaModelNotPulled, ollamaEndpointUntrusted
        case micPermissionDenied, permissionRevoked(SayMooreError.Permission)
        case audioEngineFailed, modelCorrupted, modelMissing
        case diskFull, watchdogTimeout
        case transcriptionFailed, transcriptionGarbage
        case cleanupTimedOut, cleanupFailed
        case pasteFocusChanged, pasteClipboardContended, pasteInjectionFailed
        case silentCapture, recordingTooLong, recordingLengthWarning

        var isPersistent: Bool {
            switch self {
            case .ollamaUnreachable, .ollamaModelNotPulled, .ollamaEndpointUntrusted,
                 .micPermissionDenied, .permissionRevoked, .modelCorrupted, .modelMissing:
                return true
            default:
                return false
            }
        }
    }

    static let defaultCooldown: Duration = .seconds(60)
    static let shared = NotificationCoordinator()

    private let sink: NotificationSink
    private let cooldown: Duration
    private let now: () -> ContinuousClock.Instant
    private var lastSent: [ErrorClass: ContinuousClock.Instant] = [:]
    private(set) var badge: Badge? {
        didSet { if oldValue != badge { onBadgeChange?(badge) } }
    }
    var onBadgeChange: ((Badge?) -> Void)?

    init(
        sink: NotificationSink = NotificationCenterAdapter.shared,
        cooldown: Duration = NotificationCoordinator.defaultCooldown,
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.sink = sink
        self.cooldown = cooldown
        self.now = now
    }

    func notify(_ error: SayMooreError) {
        let cls = Self.classify(error)
        let (title, body) = NotificationCenterAdapter.message(for: error)
        if let last = lastSent[cls], now() - last < cooldown {
            Log.app.debug("NotificationCoordinator coalesced: \(String(describing: cls), privacy: .public)")
        } else {
            sink.send(title: title, body: body)
            lastSent[cls] = now()
        }
        if cls.isPersistent {
            badge = Badge(key: cls, label: Self.badgeLabel(for: cls))
        }
    }

    func notify(title: String, body: String) {
        sink.send(title: title, body: body)
    }

    func clearBadge(for error: SayMooreError) {
        let cls = Self.classify(error)
        if badge?.key == cls { badge = nil }
    }

    func clearAllBadges() { badge = nil }

    static func classify(_ e: SayMooreError) -> ErrorClass {
        switch e {
        case .ollamaUnreachable: return .ollamaUnreachable
        case .ollamaModelNotPulled: return .ollamaModelNotPulled
        case .ollamaEndpointUntrusted: return .ollamaEndpointUntrusted
        case .micPermissionDenied: return .micPermissionDenied
        case .permissionRevokedMidSession(let p): return .permissionRevoked(p)
        case .audioEngineFailed: return .audioEngineFailed
        case .modelCorrupted: return .modelCorrupted
        case .modelMissing: return .modelMissing
        case .diskFull: return .diskFull
        case .watchdogTimeout: return .watchdogTimeout
        case .transcriptionFailed: return .transcriptionFailed
        case .transcriptionGarbage: return .transcriptionGarbage
        case .cleanupTimedOut: return .cleanupTimedOut
        case .cleanupFailed: return .cleanupFailed
        case .pasteFocusChanged: return .pasteFocusChanged
        case .pasteClipboardContended: return .pasteClipboardContended
        case .pasteInjectionFailed: return .pasteInjectionFailed
        case .silentCapture: return .silentCapture
        case .recordingTooLong: return .recordingTooLong
        case .recordingLengthWarning: return .recordingLengthWarning
        }
    }

    static func badgeLabel(for cls: ErrorClass) -> String {
        switch cls {
        case .ollamaUnreachable: return "Ollama down"
        case .ollamaModelNotPulled: return "Cleanup model missing"
        case .ollamaEndpointUntrusted: return "Ollama endpoint untrusted"
        case .micPermissionDenied: return "Mic blocked"
        case .permissionRevoked(let p): return "Permission revoked: \(p.rawValue)"
        case .modelCorrupted: return "Whisper model corrupted"
        case .modelMissing: return "Whisper model missing"
        default: return "Error"
        }
    }
}
```

- [ ] **Step 4: Add files to project.yml and run tests**

```bash
# project.yml: ensure SayMoore/Services/**/*.swift and SayMooreTests/**/*.swift globs already pick these up; no edit needed if globs are wildcard. Verify:
grep -n "Services\|Tests" project.yml | head
xcodegen generate
xcodebuild -project SayMoore.xcodeproj -scheme SayMoore -destination 'platform=macOS' test -only-testing:SayMooreTests/NotificationCoordinatorTests
```
Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add SayMoore/Services/NotificationCoordinator.swift SayMooreTests/NotificationCoordinatorTests.swift project.yml SayMoore.xcodeproj
git commit -m "feat(slice-9): NotificationCoordinator with per-class cooldown + persistent badge"
```

### Task A2: Route call sites through NotificationCoordinator

**Files:**
- Modify: `SayMoore/App/AppDelegate.swift` — all `NotificationCenterAdapter.shared.notify(...)` for `SayMooreError` calls become `NotificationCoordinator.shared.notify(error)`. Plain title/body calls stay on the adapter.
- Modify: `SayMoore/App/PipelineCoordinator.swift` — the `onFallback` closure passed in `startPipeline()` becomes `{ error in NotificationCoordinator.shared.notify(error) }`.

- [ ] **Step 1: Update AppDelegate.swift**

In `applicationDidFinishLaunching`, the Ollama-trust untrusted/failed branches and the Ollama-tags health probe currently use `NotificationCenterAdapter.shared.notify(.ollamaEndpointUntrusted)` and `notifier.notify(e)`. Replace with `NotificationCoordinator.shared.notify(.ollamaEndpointUntrusted)` / `NotificationCoordinator.shared.notify(e)`.

Title/body notifications about preset reload remain on `NotificationCenterAdapter` (they aren't `SayMooreError`-typed and don't need badge logic).

- [ ] **Step 2: Update PipelineCoordinator wiring in AppDelegate.startPipeline**

Replace:
```swift
onFallback: { error in notifier.notify(error) }
```
With:
```swift
onFallback: { error in NotificationCoordinator.shared.notify(error) }
```
Remove the `let notifier = NotificationCenterAdapter.shared` local binding if it becomes unused after the substitution.

- [ ] **Step 3: Build + run full test suite**

```bash
xcodebuild -project SayMoore.xcodeproj -scheme SayMoore -destination 'platform=macOS' test
```
Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add SayMoore/App/AppDelegate.swift SayMoore/App/PipelineCoordinator.swift
git commit -m "feat(slice-9): route error notifications through NotificationCoordinator"
```

### Task A3: MenuBar badge glyph

**Files:**
- Modify: `SayMoore/UI/MenuBarController.swift`
- Modify: `SayMoore/App/AppDelegate.swift` — subscribe MenuBarController to badge changes after `startPipeline`

- [ ] **Step 1: Add badge wiring in MenuBarController**

Add a stored `private var badge: NotificationCoordinator.Badge?` property. Add:

```swift
func setBadge(_ badge: NotificationCoordinator.Badge?) {
    guard self.badge != badge else { return }
    self.badge = badge
    refreshIcon()
    titleItem.title = "SayMoore (\(Self.label(for: appState.state)))" + (badge.map { " — ⚠︎ \($0.label)" } ?? "")
}
```
In the existing `refreshIcon()` / image-construction path, append a small "•" or "!" overlay or change tooltip to `badge?.label ?? "SayMoore"`. Minimal implementation: tooltip + appended title-item suffix — no image change required to keep the slice tight.

- [ ] **Step 2: Wire from AppDelegate**

At the end of `startPipeline()`:
```swift
NotificationCoordinator.shared.onBadgeChange = { [weak menuBar] badge in
    menuBar?.setBadge(badge)
}
```

- [ ] **Step 3: Manual smoke**

Build and run. Stop Ollama (`Quit Ollama from menu bar`). Trigger a dictation. Verify:
- One notification fires.
- Menu-bar item tooltip contains "Ollama down".
- Re-attempt within 60 s: no new notification, tooltip persists.
- Restart Ollama, run a clean dictation → call `NotificationCoordinator.shared.clearBadge(for: .ollamaUnreachable)` on success. (Deferred to Bundle C — Ollama supervisor task handles clear.)

- [ ] **Step 4: Commit**

```bash
git add SayMoore/UI/MenuBarController.swift SayMoore/App/AppDelegate.swift
git commit -m "feat(slice-9): menu-bar badge for persistent error conditions"
```

---

## Bundle B — Watchdog + audio device change + quit-while-non-idle

### Task B1: 30 s global watchdog in PipelineCoordinator

**Files:**
- Modify: `SayMoore/App/PipelineCoordinator.swift`
- Test: `SayMooreTests/PipelineCoordinatorWatchdogTests.swift`

- [ ] **Step 1: Write failing test**

```swift
import XCTest
@testable import SayMoore

@MainActor
final class PipelineCoordinatorWatchdogTests: XCTestCase {
    func test_watchdogFires_whenPipelineStuckInTranscribing() async throws {
        let state = AppState()
        let recorder = FakeRecorder()
        let stuck = StuckTranscription()
        let paste = PasteService(pasteboard: FakePasteboard(), keyboard: FakeKeyboard(), frontmost: FakeFrontmost(bundleID: "x"), restoreDelay: .zero)
        let presets = StubPresets()
        var fallback: SayMooreError?
        let coord = PipelineCoordinator(
            appState: state,
            recorder: recorder,
            transcription: stuck,
            paste: paste,
            presets: presets,
            cleanup: nil,
            recordingsDir: nil,
            persistRawWAV: false,
            vadService: nil,
            lengthCapCaution: 1000, lengthCapWarning: 1000, lengthCapHardStop: 1000,
            watchdogTimeout: 0.2,
            onFallback: { fallback = $0 }
        )
        coord.toggle(bundleID: "x")   // start recording
        coord.toggle(bundleID: "x")   // stop → transcribing → stuck
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(fallback, .watchdogTimeout)
        XCTAssertEqual(state.state, .idle)
    }
}

private final class StuckTranscription: TranscriptionService, @unchecked Sendable {
    func transcribe(samples: [Float], sampleRate: Double) async throws -> Transcript {
        try await Task.sleep(for: .seconds(10))
        return Transcript(text: "", segments: [], averageNoSpeechProb: 0)
    }
}
// FakeRecorder/FakePasteboard/etc: reuse existing fakes if present in test helpers,
// otherwise add minimal conforming stubs in this file.
```

If fake helpers don't yet exist in the test suite at the level needed, add minimal conforming types to this test file only (do not export). Inspect `PipelineCoordinatorTests.swift` first and reuse its helpers.

- [ ] **Step 2: Run test — should fail (missing `watchdogTimeout` parameter)**

- [ ] **Step 3: Add watchdog to PipelineCoordinator**

```swift
// New stored property:
private let watchdogTimeout: TimeInterval
private var watchdogTask: Task<Void, Never>?

// Init: add parameter `watchdogTimeout: TimeInterval = 30`, store it.
// Helper:
private func armWatchdog() {
    cancelWatchdog()
    let t = watchdogTimeout
    watchdogTask = Task { [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(t * 1_000_000_000))
        await MainActor.run { self?.fireWatchdog() }
    }
}
private func cancelWatchdog() {
    watchdogTask?.cancel()
    watchdogTask = nil
}
private func fireWatchdog() {
    guard appState.state != .idle else { return }
    Log.pipeline.fault("watchdog fired in state \(String(describing: self.appState.state), privacy: .public)")
    capturedBundleID = nil
    processingTask?.cancel()
    processingTask = nil
    cancelLengthCapTimers()
    onFallback?(.watchdogTimeout)
    appState.transition(to: .error(.watchdogTimeout))
    appState.transition(to: .idle)
}
```

Call `armWatchdog()` from `beginRecording` (immediately after `appState.transition(to: .recording)`) and from `handleSilenceAutoStop`, the manual-stop `.transcribing` transition, and `fireLengthCapHardStop`. Call `cancelWatchdog()` from `cancel()`, at the top of `transitionToError`, and inside the `processSamples` `defer` block after `processingTask = nil`.

- [ ] **Step 4: Run watchdog test → pass; run full suite → pass**

- [ ] **Step 5: Commit**

```bash
git add SayMoore/App/PipelineCoordinator.swift SayMooreTests/PipelineCoordinatorWatchdogTests.swift
git commit -m "feat(slice-9): 30s global watchdog in PipelineCoordinator"
```

### Task B2: AudioRecorder configuration-change handling

**Files:**
- Modify: `SayMoore/Services/AudioRecorder.swift`
- Modify: `SayMoore/App/PipelineCoordinator.swift` — handle the new callback
- Modify: `SayMoore/App/AppDelegate.swift` — connect callback at wiring time
- Test: `SayMooreTests/AudioRecorderConfigChangeTests.swift`

- [ ] **Step 1: Failing test (post the notification manually, assert callback fires)**

```swift
import XCTest
import AVFoundation
@testable import SayMoore

@MainActor
final class AudioRecorderConfigChangeTests: XCTestCase {
    func test_configurationChange_whileRecording_invokesCallback_andStopsEngine() async throws {
        let rec = AudioRecorder()
        var fired = false
        rec.onDeviceChange = { fired = true }
        try? rec.start()                 // may fail on CI without input; guard:
        guard rec.isRecording else { throw XCTSkip("no input device on test host") }
        NotificationCenter.default.post(
            name: AVAudioEngine.configurationChangeNotification,
            object: nil
        )
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(fired)
        XCTAssertFalse(rec.isRecording)
    }
}
```

- [ ] **Step 2: Implement**

```swift
// AudioRecorder: add stored property
var onDeviceChange: (@MainActor () -> Void)?
private var configChangeObserver: NSObjectProtocol?

// In init() add:
configChangeObserver = NotificationCenter.default.addObserver(
    forName: AVAudioEngine.configurationChangeNotification,
    object: engine,
    queue: .main
) { [weak self] _ in
    guard let self else { return }
    MainActor.assumeIsolated {
        guard self.isRecording else { return }
        Log.audio.error("AVAudioEngine configurationChange during recording — aborting")
        _ = try? self.stop()
        self.onDeviceChange?()
    }
}

// deinit (or willDeinit) removes the observer.
```

(If `AudioRecorder` doesn't yet have an `init()`, add one. Mind the `@MainActor` class isolation.)

- [ ] **Step 3: Wire in PipelineCoordinator**

Add public method:
```swift
func handleAudioDeviceChange() {
    guard appState.state == .recording else { return }
    Log.pipeline.error("audio device changed mid-recording")
    cancelLengthCapTimers()
    cancelWatchdog()
    capturedBundleID = nil
    onFallback?(.audioEngineFailed(underlying: RecorderError.deviceChanged))
    appState.transition(to: .error(.audioEngineFailed(underlying: RecorderError.deviceChanged)))
    appState.transition(to: .idle)
}
```
Add `case deviceChanged` to the existing `RecorderError` enum in `AudioRecorder.swift`.

In `AppDelegate.startPipeline()`:
```swift
recorder.onDeviceChange = { [weak coordinator] in
    coordinator?.handleAudioDeviceChange()
}
```

- [ ] **Step 4: Run new test + full suite**

- [ ] **Step 5: Commit**

```bash
git add SayMoore/Services/AudioRecorder.swift SayMoore/App/PipelineCoordinator.swift SayMoore/App/AppDelegate.swift SayMooreTests/AudioRecorderConfigChangeTests.swift
git commit -m "feat(slice-9): abort recording on AVAudioEngine configurationChange"
```

### Task B3: Quit-while-non-idle

**Files:**
- Modify: `SayMoore/App/AppDelegate.swift`

- [ ] **Step 1: Implement `applicationShouldTerminate(_:)`**

```swift
func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    switch appState.state {
    case .idle, .error:
        return .terminateNow
    case .recording:
        let alert = NSAlert()
        alert.messageText = "Discard current dictation and quit?"
        alert.informativeText = "Recording will be discarded."
        alert.addButton(withTitle: "Discard & Quit")
        alert.addButton(withTitle: "Cancel")
        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            coordinator?.cancel()
            return .terminateNow
        }
        return .terminateCancel
    case .transcribing, .cleaning, .pasting:
        // Grant up to 5s for the in-flight processingTask to finish.
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline && self.appState.state != .idle {
                try? await Task.sleep(for: .milliseconds(100))
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
```

- [ ] **Step 2: Manual test**

Add an entry in `docs/manual-tests/slice-9.md` (created in Bundle C). Verify:
- Cmd-Q while idle → quits.
- Cmd-Q while recording → confirmation alert; Cancel keeps app running; Discard quits.
- Cmd-Q while transcribing/cleaning/pasting → "Finishing…" delay (≤5 s) then quit.

- [ ] **Step 3: Commit**

```bash
git add SayMoore/App/AppDelegate.swift
git commit -m "feat(slice-9): block Cmd-Q while pipeline non-idle"
```

---

## Bundle C — Permission revoke + Ollama supervisor + model corruption + catalog

### Task C1: MicrophonePermissionMonitor

**Files:**
- Create: `SayMoore/Services/MicrophonePermissionMonitor.swift`
- Test: `SayMooreTests/MicrophonePermissionMonitorTests.swift`
- Modify: `SayMoore/App/AppDelegate.swift` — start/stop alongside `hotkey.start()`

- [ ] **Step 1: Failing test (clock-injectable monitor)**

```swift
import XCTest
@testable import SayMoore

@MainActor
final class MicrophonePermissionMonitorTests: XCTestCase {
    func test_emitsRevokedEvent_whenStatusFlipsFromAuthorizedToDenied() async {
        var statuses: [AVAuthorizationStatus] = [.authorized, .authorized, .denied]
        var fired = false
        let mon = MicrophonePermissionMonitor(
            poll: .milliseconds(10),
            statusProvider: { statuses.removeFirst() },
            onRevoked: { fired = true }
        )
        mon.start()
        try? await Task.sleep(for: .milliseconds(80))
        mon.stop()
        XCTAssertTrue(fired)
    }
}
```

- [ ] **Step 2: Implement**

```swift
import AVFoundation
import Foundation

@MainActor
final class MicrophonePermissionMonitor {
    private let poll: Duration
    private let statusProvider: () -> AVAuthorizationStatus
    private let onRevoked: () -> Void
    private var task: Task<Void, Never>?
    private var lastStatus: AVAuthorizationStatus?

    init(
        poll: Duration = .seconds(2),
        statusProvider: @escaping () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .audio) },
        onRevoked: @escaping () -> Void
    ) {
        self.poll = poll
        self.statusProvider = statusProvider
        self.onRevoked = onRevoked
    }

    func start() {
        stop()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let s = await MainActor.run { self.statusProvider() }
                await MainActor.run {
                    if self.lastStatus == .authorized && s != .authorized {
                        self.onRevoked()
                    }
                    self.lastStatus = s
                }
                try? await Task.sleep(for: self.poll)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
```

- [ ] **Step 3: Wire from AppDelegate**

```swift
private var micMonitor: MicrophonePermissionMonitor?

// At the end of startPipeline():
let mon = MicrophonePermissionMonitor(onRevoked: { [weak self] in
    NotificationCoordinator.shared.notify(.permissionRevokedMidSession(.microphone))
    self?.coordinator?.cancel()
})
mon.start()
self.micMonitor = mon
```

Add a notification body for `.permissionRevokedMidSession(.microphone)` in `NotificationCenterAdapter.message(for:)` with deeplink hint: "Grant microphone access in System Settings → Privacy & Security → Microphone."

- [ ] **Step 4: Run tests + commit**

```bash
git add SayMoore/Services/MicrophonePermissionMonitor.swift SayMoore/Services/NotificationCenterAdapter.swift SayMoore/App/AppDelegate.swift SayMooreTests/MicrophonePermissionMonitorTests.swift
git commit -m "feat(slice-9): detect mid-session mic permission revocation"
```

### Task C2: OllamaSupervisor cold-spawn

**Files:**
- Create: `SayMoore/Services/OllamaSupervisor.swift`
- Test: `SayMooreTests/OllamaSupervisorTests.swift`
- Modify: `SayMoore/App/AppDelegate.swift` — call supervisor from existing health-probe block on `.ollamaUnreachable`, then retry `tags()` once.

- [ ] **Step 1: Failing test (inject Process-launcher)**

```swift
import XCTest
@testable import SayMoore

@MainActor
final class OllamaSupervisorTests: XCTestCase {
    func test_spawnInvokesLauncher_whenBinaryExists() async {
        var launched: [URL] = []
        let sup = OllamaSupervisor(
            binaryLocator: { URL(fileURLWithPath: "/usr/local/bin/ollama") },
            launcher: { url in launched.append(url) }
        )
        await sup.coldSpawn()
        XCTAssertEqual(launched.first?.path, "/usr/local/bin/ollama")
    }

    func test_spawnIsNoOp_whenNoBinary() async {
        var launched: [URL] = []
        let sup = OllamaSupervisor(
            binaryLocator: { nil },
            launcher: { url in launched.append(url) }
        )
        await sup.coldSpawn()
        XCTAssertTrue(launched.isEmpty)
    }
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation

@MainActor
final class OllamaSupervisor {
    private let binaryLocator: () -> URL?
    private let launcher: (URL) -> Void

    static func defaultBinaryLocator() -> URL? {
        let candidates = ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama", "/Applications/Ollama.app/Contents/Resources/ollama"]
        return candidates.map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func defaultLauncher(_ url: URL) {
        let proc = Process()
        proc.executableURL = url
        proc.arguments = ["serve"]
        // Don't keep stdio attached; let it run detached.
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch {
            Log.cleanup.error("OllamaSupervisor launch failed: \(String(describing: error), privacy: .public)")
        }
    }

    init(
        binaryLocator: @escaping () -> URL? = OllamaSupervisor.defaultBinaryLocator,
        launcher: @escaping (URL) -> Void = OllamaSupervisor.defaultLauncher
    ) {
        self.binaryLocator = binaryLocator
        self.launcher = launcher
    }

    func coldSpawn() async {
        guard let url = binaryLocator() else {
            Log.cleanup.info("OllamaSupervisor: no ollama binary found")
            return
        }
        Log.cleanup.info("OllamaSupervisor: launching \(url.path, privacy: .public) serve")
        launcher(url)
    }
}
```

- [ ] **Step 3: Wire into AppDelegate health probe**

In the existing `Task.detached` block in `startPipeline()` that calls `ollama.tags()`, change the `catch let e as SayMooreError` arm so that on `.ollamaUnreachable` it calls supervisor + retries once:

```swift
} catch let e as SayMooreError {
    if case .ollamaUnreachable = e {
        await OllamaSupervisor().coldSpawn()
        try? await Task.sleep(for: .seconds(3))
        if let tags = try? await ollama.tags() {
            Log.cleanup.info("ollama up after cold-spawn, models=\(tags.joined(separator: ","), privacy: .public)")
            await MainActor.run { NotificationCoordinator.shared.clearBadge(for: .ollamaUnreachable) }
            return
        }
    }
    await MainActor.run { NotificationCoordinator.shared.notify(e) }
}
```

- [ ] **Step 4: Run tests + commit**

```bash
git add SayMoore/Services/OllamaSupervisor.swift SayMoore/App/AppDelegate.swift SayMooreTests/OllamaSupervisorTests.swift
git commit -m "feat(slice-9): cold-spawn ollama serve on unreachable + clear badge on recovery"
```

### Task C3: Model corruption — surface + retry path

**Files:**
- Modify: `SayMoore/App/ModelBootstrap.swift` — if `downloader.currentStatus()` returns `.complete` but a subsequent SHA256 verification (already done by ModelDownloader on completion) wasn't honoured, treat as corrupted.

- [ ] **Step 1: Inspect existing `ModelBootstrap.run()`**

Read `SayMoore/App/ModelBootstrap.swift` and verify how it surfaces SHA mismatch today. If SHA verification already lives in `ModelDownloader.verify()` and emits an error on mismatch, simply ensure the error reaches `NotificationCoordinator.shared.notify(.modelCorrupted)` and offer "Restart to re-download" via the existing `ModelDownloadWindow.present` retry callback.

- [ ] **Step 2: Hook notification**

In `applicationDidFinishLaunching`'s bootstrap path, after `await boot.run()` resolves with an error of `.modelCorrupted`/`.modelMissing` (introspect via a new `bootstrap.lastError` property if not already exposed):
```swift
if case .some(.modelCorrupted) = bootstrap?.lastError {
    NotificationCoordinator.shared.notify(.modelCorrupted)
}
```

- [ ] **Step 3: Manual test**

Document the manual procedure in `docs/manual-tests/slice-9.md`: truncate the model file with `dd if=/dev/zero of=~/Library/Application\ Support/SayMoore/models/ggml-small.en.bin bs=1 count=10 conv=notrunc`, relaunch, verify `.modelCorrupted` notification + re-download window.

- [ ] **Step 4: Commit**

```bash
git add SayMoore/App/ModelBootstrap.swift SayMoore/App/AppDelegate.swift
git commit -m "feat(slice-9): surface model-corrupted via NotificationCoordinator + re-download"
```

### Task C4: Error-recovery catalog doc + manual-test matrix

**Files:**
- Create: `docs/error-recovery.md`
- Create: `docs/manual-tests/slice-9.md`

- [ ] **Step 1: Write `docs/error-recovery.md`**

Table mapping every case of `SayMooreError` to: (a) trigger, (b) user-visible notification copy, (c) state-machine consequence, (d) whether it sets a persistent badge, (e) recovery path (automatic or manual). Use the existing `NotificationCenterAdapter.message(for:)` text as the source of truth for copy. One row per case.

- [ ] **Step 2: Write `docs/manual-tests/slice-9.md`**

Sections (mirror `docs/manual-tests/slice-4.md` structure):
1. Storm test — `kill ollama`, fire 5 dictations within 60s, assert exactly 1 notification + persistent badge.
2. Watchdog — set debug timeout to 2 s; trigger via debug menu or by stubbing transcription; verify reset-to-idle + notification.
3. Audio device change — start recording, unplug USB mic; verify graceful abort + notification.
4. Mic revoke — start app, revoke mic permission in Settings, start recording; verify revoke notification + cancel.
5. Cmd-Q matrix — idle / recording / transcribing-paste; verify alert / discard / finishing behaviour.
6. Model corruption — `dd` truncate model, relaunch; verify re-download offered.

- [ ] **Step 3: Commit**

```bash
git add docs/error-recovery.md docs/manual-tests/slice-9.md
git commit -m "docs(slice-9): error-recovery catalog + manual test matrix"
```

---

## Self-review checklist (the planner runs this before handoff)

- **Spec coverage** — PRD §Slice 9 deliverables:
  - NotificationCoordinator coalescing → Task A1
  - Menu-bar badge → Tasks A1 + A3
  - 30s watchdog → Task B1
  - Ollama cold-spawn → Task C2
  - Mic-permission revoke deeplink → Task C1 (deeplink wording added to NotificationCenterAdapter.message in C1 Step 3)
  - Cleanup hangs >10s → already covered by existing OllamaService URLRequest `timeoutInterval`; surfaced via `.cleanupTimedOut` through the existing onFallback path. No new code needed.
  - Paste focus-changed / contended / injection-failed → already surfaced via `.pasteFocusChanged` etc.; now routes through NotificationCoordinator (Task A2).
  - Whisper model corrupted → Task C3
  - **Disk full while writing history.jsonl** → deferred: HistoryStore not implemented yet (PRD critical-files list, not delivered in prior slices). Plan calls this out in Architecture; tracked as Slice 9 follow-up rather than stubbed.
  - Watchdog timeout case → Task B1
  - Audio device change mid-recording → Task B2
  - Quit while non-idle → Task B3
  - docs/error-recovery.md catalog → Task C4
- **Placeholders** — no TBD / "implement later" / "similar to" references. Each code step has the full snippet.
- **Type consistency** — `NotificationCoordinator.ErrorClass` cases match `SayMooreError` cases as enumerated in `classify(_:)`. The `Badge` struct holds `(key: ErrorClass, label: String)` everywhere it appears. `MicrophonePermissionMonitor.onRevoked` is a `() -> Void`; supervisor uses `coldSpawn() async`. `RecorderError.deviceChanged` is added in Task B2 alongside the call site.

---

## Execution Handoff

Plan saved to `docs/superpowers/plans/2026-05-19-slice-9-recovery-watchdog-coalescing.md`. Two execution options:

1. **Subagent-Driven (recommended)** — fresh subagent per task, review between, fast iteration. Good fit for this slice because Bundles A→B→C have a strict dependency order but inter-bundle tasks are independent.
2. **Inline Execution** — execute tasks in this session using executing-plans, batch checkpoints at end of each bundle.
