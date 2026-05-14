# Slice 4 follow-ups

Distilled from a four-agent adversarial review (UX / security / maintainability / codebase quality) of `a30e94e` on 2026-05-14, validated against actual code by the main reviewing thread. Nothing here was push-blocking; everything is queued work.

## Bundle A — small mechanical cluster (next batch)

### A1. Make PresetWatcher safe under teardown + concurrent calls (C1 + C2)
- **Severity:** Critical (quit-only blast radius today)
- **Where:** `SayMoore/Services/PresetWatcher.swift`
- **Observation:** `Unmanaged.passUnretained(self).toOpaque()` is stored as the FSEvent callback `info` with `retain: nil, release: nil`. `teardown()` does not synchronize with the private dispatch queue. `started` / `stream` are plain `var` mutated without a lock; `@unchecked Sendable` silences the compiler.
- **Shape of fix:** convert `PresetWatcher` to an `actor`, OR pass `+1` retain by providing matching `retain`/`release` C function pointers (Unmanaged.passRetained / Unmanaged.fromOpaque + release in the C release callback). Either way, invalidate from the private queue inside `queue.sync {}` during teardown. Drop `@unchecked Sendable`.

### A2. Bound presets.json on load (M3)
- **Severity:** Major
- **Where:** `SayMoore/Services/PresetStore.swift` → `loadFromDisk`
- **Observation:** No file-size gate, no overrides-count cap, no per-template length cap. `Data(contentsOf:)` + `JSONSerialization` will happily allocate.
- **Shape of fix:** 512 KB file-size gate, ≤50 overrides, ≤4 KB per `promptTemplate`. Reject with new typed `PresetStoreError` cases so the existing banner path surfaces them.

### A3. Compile-time-gate `persistRawWAV` (M4)
- **Severity:** Major
- **Where:** `SayMoore/Pipeline/PipelineCoordinator.swift` (init signature + storage)
- **Observation:** `persistRawWAV: Bool = false` lives in the Release binary. Nothing flips it today, but the mechanism is reachable.
- **Shape of fix:** wrap the field + branch in `#if DEBUG`. Add a launch-time `RecordingPaths` purge in Release as belt-and-braces.

### A4. "Edit Presets…" menu item (M9)
- **Severity:** Major (UX)
- **Where:** `SayMoore/UI/MenuBarController.swift`
- **Observation:** Menu has "Reload Presets" but no way to discover or open `~/Library/Application Support/SayMoore/presets.json`. Library is hidden in Finder; the whole feature is invisible without source-code knowledge.
- **Shape of fix:** add an "Edit Presets…" item that calls `NSWorkspace.shared.activateFileViewerSelecting([presetsURL])`. One-liner.

### A5. Drop CleanupService.init default arg (M11)
- **Severity:** Major (latent test trap)
- **Where:** `SayMoore/Services/CleanupService.swift:19`
- **Observation:** `presets: PresetStore = PresetStore()` — omitting the arg constructs a second store with disk I/O at init time. Today only production callsites supply it; first omitted callsite explodes.
- **Shape of fix:** remove the default. Make `presets:` required. Update any tests that need a stub to introduce a `PresetResolving` protocol or inject a custom in-memory `PresetStore`.

### A6. SayMooreError Equatable safety (M13)
- **Severity:** Major (correctness)
- **Where:** `SayMoore/Errors/Errors.swift` (manual `==` implementation)
- **Observation:** `default: return false` arm means any new case added without a matching `==` arm is silently `!=` to itself, breaking `AppState.State.error(...)` equality checks and tests.
- **Shape of fix:** split into payload-bearing and payload-free cases, derive `Equatable` for the latter. OR add a reflection-based coverage test that fails when a new case is missing an `==` arm.

### (Bonus, if scope allows) A7. "Presets reloaded." banner should skip when unchanged (M10)
- **Severity:** Minor
- **Where:** `SayMoore/UI/MenuBarController.swift` + `SayMoore/App/AppDelegate.swift:reloadPresetsAndNotifyOnFailure`
- **Shape:** track whether default/overrides actually changed before posting the success banner.

## Bundle B — deferred to natural homes

| Finding | Severity | Natural home |
|---|---|---|
| M1 — Pasteboard hygiene (Universal Clipboard / Alfred / Raycast snapshot every dictation through a ~400 ms window). Move to custom pasteboard type. | Major | Dedicated privacy pass after Slice 6, or fold into Slice 11 release prep. |
| M2 — Ollama endpoint trust (any process binding `127.0.0.1:11434` can impersonate). Probe `/api/version` + check owning process identity at startup. | Major | Slice 9 (recovery handlers + watchdog). |
| M5 — `AppState.onTransition` is single-slot; second observer silently clobbers. | Major | Fix at the start of Slice 6 — Slice 6 adds the second observer. |
| M6 — Banner drops `PresetStoreError` discriminant. | Major (UX) | Slice 9 notification coalescing pass. |
| M7 — `NotificationCenterAdapter.send` uses `UUID().uuidString` per call → banner storms. | Major | Slice 9. |
| M8 — `AudioFeedbackService.muted` frozen at init. | Major (UX) | Slice 6 menu polish (likely adds a "Mute Chimes" toggle alongside). |

## Bundle C — minor / nits / chore pass

- **C3 (prompt-injection fence):** XML-delimit `{{transcript}}` in `CleanupService.buildPrompt` with explicit instructions to the model that content between tags is verbatim user dictation, not instructions. Cheap. Bundle whenever CleanupService is next touched.
- **Q1:** Redundant `Task { @MainActor in ... }` inside `reloadPresetsAndNotifyOnFailure` (already on `@MainActor`).
- **Q2:** `PresetStore.defaultFileURL` uses `.first!` force-unwrap. Replace with `preconditionFailure` for crash-triage clarity.
- **Misc:**
  - `CleanupService.swift` shadows the `raw:` parameter with `let raw = ...`. Rename the local to `response`.
  - `PresetStoreTests.swift:204-212` — `testPresetForBundleIDReturnsDefault` still says `// Slice 4 will change this` in a comment. Slice 4 has shipped; rename + delete the comment.
  - `PresetWatcher.swift:5-6` doc comment claims `onChange` runs "on the calling queue." It actually runs on the private FSEvents queue. Fix the doc.
  - `project.yml:60` — `postBuildScript` runs on every build because `basedOnDependencyAnalysis: false`. Add a synthetic `inputFiles: ["$(CODE_SIGN_IDENTITY)"]` so it only re-runs when the signing identity changes.
  - `presets.example.json` default vs `PresetStore.defaultPromptTemplate` will silently drift. Add a test asserting equality, or load the constant from the resource.
  - `PresetStoreTests.swift:24` uses `try!` on `String.data(using: .utf8)` — replace with `XCTUnwrap` for clearer test failures.
  - `PresetWatcher.swift` — `(path as NSString).lastPathComponent` on a path with a trailing slash can return empty. Normalize via `URL(fileURLWithPath: path).lastPathComponent`.
  - `project.yml:21` — `SWIFT_TREAT_WARNINGS_AS_ERRORS: NO`. Consider flipping for the production target.

## Dropped (invalidated by code inspection)

- ~~M12 AVAudioConverter endOfStream~~ — `AudioFormatConverter.convert` already uses `.noDataNow` with explanatory comment ("this converter is reused across many tap buffers. Signaling end-of-stream finalizes the resampler"). Memory was stale.
- ~~Q3 HTTPS scheme assertion~~ — `WhisperModel.remoteURL` is already `https://`.

## Source

Full review thread is in the Claude Code session log from 2026-05-14. Four sonnet agents under separate lenses, then Opus consolidation + per-finding validation against the codebase.
