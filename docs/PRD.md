# SayMoore — Product Requirements Document (v1.0)

## Context

Tracy has been paying for Glaido (or a similar voice-to-clean-text tool) and wants to replace it with a local, free, durable equivalent. The macOS Dictation built-in is slow, cloud-dependent, and produces unstructured transcripts that need manual cleanup before they're usable in Slack, Mail, Xcode, etc. Voice tools that *do* clean transcripts are subscription products with API costs and outage exposure.

SayMoore is a single-user, on-device replacement: hit a hotkey, talk, get cleaned text pasted into the focused field, with per-app tone presets. Everything runs on Tracy's M2 Ultra Mac Studio (64GB) — Whisper transcription in-process, Qwen 2.5 7B cleanup via local Ollama. Zero recurring cost, zero network dependency at runtime.

Goal: **delete macOS Dictation and a paid product in one move**, with a tool that improves over both.

---

## Mission

Build a Mac menu-bar app that converts spoken audio into context-appropriately-cleaned text, pasted into the focused field, in under 3 seconds end-to-end, fully on-device.

## Target user

Tracy Moore. One user. No multi-user concerns. No accessibility/i18n requirements beyond what AppKit gives for free.

## Success criteria (v1.0 ship gate)

1. Average end-to-end latency from "stop talking" to "text appears in field" ≤ 3.0s for ≤30s clips on M2 Ultra.
2. ≥95% paste accuracy across 20 representative dictations into Slack, Mail, Xcode, Notes, Messages.
3. 50 consecutive dictations with no leaks, hangs, or restart needed (Instruments-verified).
4. Fresh-Mac install walkthrough takes ≤5 minutes from "downloaded the .dmg" to "first successful dictation," following only the README.
5. All four permissions (Mic, Accessibility, Input Monitoring, Notifications) recover cleanly when revoked: the app surfaces the permission wizard on the next interaction without crashing.
6. Sparkle update from v0.9 → v1.0 succeeds on a clean install.

---

## Locked decisions

(Confirmed during brainstorming and adversarial review. Do not relitigate without explicit Tracy override.)

| Area | Decision |
|---|---|
| Hotkey | **Ctrl-Ctrl** (double-tap left or right Control), toggle mode. Recognizer fires only when Ctrl goes down→up with no other key while held; any intervening key event cancels the in-progress sequence. ≤300ms between taps. |
| Cancel gesture | **Esc** intercepted **only while `AppState == .recording`**. At all other times Esc passes through to the focused app untouched. |
| Re-press during processing | **Block with soft busy tone**, ignore the press. |
| Frontmost-app capture | **At first Ctrl keydown inside `HotkeyService`**, before any app activation can race. Bundle ID is asserted to never equal `com.seemoretmoore.saymoore`; if it ever does, fall back to the previously-frontmost app. |
| Cursor indicator | **Static at hotkey-press position**, not mouse-following. **Plus** a hard-to-miss "● Recording" HUD shown on the active display (centered or near-caret, borderless, non-focus-stealing) so fullscreen apps on a second display still get clear feedback. |
| Default cleanup style | **Light cleanup**: remove filler (uh/um/like/you know), fix self-corrections, preserve voice and word choice. |
| Whisper integration | **In-process via SwiftPM `whisper.cpp` package** (warm model in RAM across dictations). **Subprocess fallback** to bundled `whisper-cli` if Slice 1.5 spike fails. |
| Whisper model | `ggml-large-v3-turbo.bin`, downloaded first launch with HTTP Range resume. SHA256 **hardcoded in the signed app binary** (never fetched at runtime). `.download-in-progress` sentinel file written alongside; SHA256 verified only when sentinel removed (= file complete). Stored at `~/Library/Application Support/SayMoore/models/`. |
| Cleanup LLM | Ollama `qwen2.5:7b-instruct` (Q4_K_M default), `OLLAMA_KEEP_ALIVE=24h`. |
| Ollama model handling | **Fixed model in v1.** If not pulled, surface notification with `ollama pull qwen2.5:7b-instruct` instruction. Settings pane / manifest deferred to v1.1. |
| Ollama startup | Probe `localhost:11434/api/tags`. If down, attempt `ollama serve` background spawn with notification. |
| VAD | Silero VAD via whisper.cpp built-in, behind a `VADBackend` protocol. 10s silence auto-stop; 90s hard cap; 80s warning notification. |
| Garbage detection | Discard with notification if Whisper average `no_speech_prob > 0.9`. |
| Text injection | Save clipboard → set transcript → synthetic Cmd+V via CGEvent → restore clipboard. **Two integrity checks before restore:** (a) `NSPasteboard.changeCount` must equal what SayMoore wrote (no other process touched the clipboard); (b) frontmost app at paste-time must equal the app captured at recording-start. If either check fails: skip restore, leave transcript on clipboard, show notification "Focus changed — paste manually" (or "Clipboard contended — your text is on the clipboard"). 200ms restore delay is empirically tuned and logged when exceeded. **Clipboard-fidelity rule for v1: string-only restore.** Before clearing, capture only `.string` type into a `String?`; non-string clipboard contents (images, RTF, file URLs) are dropped on restore with a notification "Non-text clipboard contents were not preserved." Full multi-type fidelity is v1.1 work. **`bundleID == nil` rule:** if captured bundle ID is nil at recording-start (no frontmost app or app without bundle ID), use the default preset; if current bundle ID is nil at paste-time, treat as focus-changed and abort to clipboard-only. |
| Fast path for short utterances | If recorded audio is < 1.5 seconds OR the post-transcription text is ≤ 3 words, skip Ollama cleanup and paste the raw Whisper output. Goal: keep "yes" / "ok" / "thanks" responses sub-second. The fast-path threshold is configurable in `presets.json` under a `fastPath` section (`minDurationMs`, `maxWordCount`); ships with the defaults above. |
| LSUIElement | `LSUIElement = true` in `Info.plist`. Menu-bar-only app: no Dock icon, no Cmd-Tab entry. Locked from Slice 0. |
| Quit while non-idle | Cmd-Q during `.recording` shows a confirmation alert ("Discard the current dictation and quit?"). Cmd-Q during `.transcribing` or `.cleaning` waits up to 5 seconds for completion before forcing quit; status bar shows "Finishing…" during the grace window. Cmd-Q during `.idle` quits immediately. |
| Context awareness | Tier 1 (frontmost-app bundle ID) + Tier 3 (per-app overrides). NO accessibility-tree reading in v1. |
| Tone presets | `~/Library/Application Support/SayMoore/presets.json`, hot-reload via `FSEventStream` watching the parent directory (robust against atomic temp-rename writes from real editors). Schema: `{ "default": "...", "overrides": { "com.bundle.id": "..." } }`. Ship `presets.example.json` for Slack, Mail, Xcode, Notes, Messages. |
| History log | 50-entry rolling JSONL at `~/Library/Application Support/SayMoore/history.jsonl`. Fields: `timestamp, duration_ms, app_bundle_id, preset_name, raw_transcript, cleaned_transcript, no_speech_prob, char_count`. Audio NOT persisted. |
| Code signing | Self-signed cert in login Keychain via `scripts/setup-signing.sh`. **Idempotent** — refuses to regenerate if a "SayMoore Self-Sign" cert already exists; `--force-regen` flag required for intentional rotation, with a banner explaining that Accessibility/Input-Monitoring permissions will need re-granting. No paid Apple Developer Program. |
| Sparkle key | EdDSA private key in Keychain entry `SayMoore Sparkle EdDSA`. `scripts/build-release.sh` reads from Keychain. Never in repo, never on disk plaintext. |
| Auto-update | Sparkle 2 + EdDSA appcast on public GitHub Releases. |
| Min macOS | 14 (Sonoma). |
| Bundle ID | `com.seemoretmoore.saymoore`. |
| Repo | `github.com/seemoretmoore/saymoore`, MIT, public. |
| GitHub Project | Created **after PRD approval**. |

### Default cleanup prompt (locked tone target)

```
You are a transcription cleanup assistant. The user dictated text that was transcribed by Whisper.
Your job: remove filler words (uh, um, like, you know), fix obvious self-corrections (e.g., "Friday — no, Monday" → "Monday"), and produce natural-sounding text in the user's voice.

Rules:
- Preserve the user's word choice and phrasing. Do NOT rewrite for style.
- Do NOT add information that wasn't dictated.
- Do NOT add commentary, headers, or formatting unless the user explicitly dictated it.
- Output ONLY the cleaned text. No preamble, no quotes, no explanation.
- If the input is already clean, return it unchanged.

Input transcript:
{{transcript}}
```

The exact wording will be tuned during Slice 3 against real Tracy dictations.

---

## Cross-cutting concerns

These apply across all slices. Established up front to prevent retrofit pain.

### Threading model (Swift Concurrency)

- `AppState` is **`@MainActor`**, holds **only** the state enum and transition logic. No service references.
- A `PipelineCoordinator` (also `@MainActor`) holds references to all services and orchestrates the recording → transcribe → clean → paste pipeline as a sequence of `await` calls. Services are stateless workers from the coordinator's perspective.
- Each service is a `final class: Sendable` with internal state protected by an `actor`-style serial queue or a private `actor`. Services never touch UI directly.
- The audio render block (AVAudioEngine tap) writes raw 16kHz mono float32 samples into a **lock-free single-producer/single-consumer ring buffer**. No Swift allocations on the audio thread.
- Whisper transcription runs in `Task.detached(priority: .userInitiated)`. It is not re-entrant — only one `whisper_full()` call may be in flight at a time, enforced by an actor.
- All state transitions hop back to the main actor via `await MainActor.run`. The project compiles under `-strict-concurrency=complete`.

### Error type

A single shared `enum SayMooreError: Error` lives in `SayMoore/Core/Errors.swift`. Cases include at minimum: `.micPermissionDenied`, `.audioEngineFailed(underlying:)`, `.transcriptionFailed(underlying:)`, `.transcriptionGarbage`, `.cleanupTimedOut`, `.cleanupFailed(underlying:)`, `.ollamaUnreachable`, `.ollamaModelNotPulled`, `.pasteFocusChanged(captured:current:)`, `.pasteClipboardContended`, `.pasteInjectionFailed`, `.modelMissing`, `.modelCorrupted`, `.diskFull`, `.permissionRevokedMidSession(.microphone | .accessibility | .inputMonitoring)`. Services throw `SayMooreError`; `PipelineCoordinator` catches and transitions `AppState` to `.error(SayMooreError)`.

### Logging

`Logger` (Apple's `os.Logger`) configured at app start with subsystem `com.seemoretmoore.saymoore` and one category per service (`hotkey`, `audio`, `vad`, `transcribe`, `cleanup`, `paste`, `context`, `presets`, `history`, `permissions`, `model`, `pipeline`). State transitions log at `.debug`, recoverable failures at `.error`, fatal/unrecoverable at `.fault`. Set up in Slice 0.

### Global watchdog

`PipelineCoordinator` arms a 30-second watchdog whenever it transitions away from `.idle`. **The watchdog timer resets on every successful state transition** (recording→transcribing, transcribing→cleaning, etc.) — only a single state held continuously for 30s trips it. If the state machine has not returned to `.idle` within 30s of the last transition, the coordinator force-cancels in-flight tasks, transitions to `.error(.watchdogTimeout)`, fires a notification ("SayMoore stuck — recovered"), and returns to `.idle`. This is the safety net for any unanticipated hang path. Per-stage soft timeouts (cleanup 10s, transcribe ~5s) fire first under normal conditions; the watchdog catches only the cases those don't.

### Error state transition ownership

Every error transition is fired by `PipelineCoordinator`, which owns the rule: on entering any `.error(SayMooreError)` state, the coordinator immediately schedules `Task { @MainActor in await NotificationCoordinator.shared.notify(error); appState.transition(to: .idle) }`. There is no error state without an exit transition; the watchdog catches any path that violates this invariant.

### Notification coalescing (per error class)

A `NotificationCoordinator` deduplicates user-facing notifications per error case for a 60-second cooldown window. Persistent error conditions (Ollama down, mic revoked) additionally surface as a menu-bar status badge so users aren't pelted with toasts. Implemented in Slice 9.

---

## State machine

```
idle ──Ctrl-Ctrl───▶ recording ──Ctrl-Ctrl/VAD/90s──▶ transcribing ──▶ cleaning ──▶ pasting ──▶ idle
  │                     │
  │                     └── Esc ──▶ idle (discarded, soft cancel sound)
  │
  └── Ctrl-Ctrl during {transcribing, cleaning, pasting} ──▶ busy-tone, no state change

Error sub-states (each forces transition back to idle after notification):
  recording ──┬─▶ error(.audioEngineFailed)
              └─▶ error(.permissionRevokedMidSession(.microphone))
  transcribing ──┬─▶ error(.transcriptionFailed)
                 └─▶ error(.transcriptionGarbage)             ← no_speech_prob > 0.9
  cleaning ──┬─▶ error(.cleanupTimedOut)        → fall back to raw transcript, continue to pasting
             ├─▶ error(.cleanupFailed)          → fall back to raw transcript, continue to pasting
             └─▶ error(.ollamaUnreachable)      → fall back to raw transcript, continue to pasting
  pasting ──┬─▶ error(.pasteFocusChanged)       → leave on clipboard, notify
            ├─▶ error(.pasteClipboardContended) → leave on clipboard, notify
            └─▶ error(.pasteInjectionFailed)    → leave on clipboard, notify

Watchdog: any non-idle state held >30s ──▶ error(.watchdogTimeout) ──▶ idle.
```

---

## Architecture (high-level)

```
SayMoore.app (menu-bar, AppKit + SwiftUI for the wizard)
   │
   ├─► AppState (@MainActor)        — pure state machine; no service refs
   ├─► PipelineCoordinator (@MainActor) — owns services, sequences pipeline
   │
   ├─► HotkeyService                — global Ctrl-Ctrl listener (CGEventTap)
   │     └─ captures frontmost bundleID at first Ctrl keydown
   ├─► AppContextService            — bundleID resolution helpers
   ├─► AudioRecorder                — AVAudioEngine, 16kHz mono float32, ring buffer
   │     └─► VADService             — Silero behind VADBackend protocol
   ├─► TranscriptionService         — in-process whisper.cpp (warm model, actor-serialized)
   ├─► PresetStore                  — JSON, hot-reload via FSEventStream on parent dir
   ├─► CleanupService               — Ollama HTTP, 10s timeout
   ├─► PasteService                 — NSPasteboard + synthetic CGEvent Cmd+V
   │                                  changeCount sentinel + paste-time focus re-check
   ├─► HistoryStore                 — rolling JSONL, atomic writes
   ├─► PermissionsManager           — TCC status checks
   ├─► ModelDownloader              — HTTP Range + .download-in-progress sentinel + SHA256
   └─► NotificationCoordinator      — coalescing + menu-bar error badge

UI:
   ├─► MenuBarController            — NSStatusItem with state-driven icon + pulse + error badge
   ├─► CursorIndicator              — borderless NSWindow at .floating
   ├─► RecordingHUD                 — borderless NSWindow on active display, "● Recording"
   ├─► SoundEffects                 — NSSound start.aiff / stop.aiff / cancel.aiff / busy.aiff
   └─► PermissionsWizard            — first-run SwiftUI flow with deeplinks

Persistence (~/Library/Application Support/SayMoore/):
   ├─► models/ggml-large-v3-turbo.bin
   ├─► presets.json
   └─► history.jsonl
```

---

## Vertical slices

Each slice is end-to-end working software. After each, a `[CHECKPOINT]` for Tracy sign-off. No slice begins until prior is approved.

### Slice 0 — Scaffold + signing + cross-cutting infrastructure
**Goal:** Empty menu-bar app builds, installs, launches without crash. Signing identity stable across rebuilds. Logger and `SayMooreError` are in place from day one.
**Deliverables:**
- Xcode project with `-strict-concurrency=complete` enabled
- `Info.plist` with all 4 permission strings **and `LSUIElement = true`** (menu-bar-only, no Dock icon)
- MIT `LICENSE`, `README.md` skeleton, `.gitignore`
- `scripts/setup-signing.sh` — **idempotent**: detects existing cert, refuses to regenerate, requires `--force-regen`
- `scripts/build-release.sh` skeleton
- `SayMoore/Core/Errors.swift` (the `SayMooreError` enum)
- `SayMoore/Core/Logging.swift` (Logger categories)
- `SayMoore/App/AppState.swift` (state enum only, `@MainActor`)
- `SayMoore/App/PipelineCoordinator.swift` (skeleton, no logic yet)

**Acceptance:**
- `bash scripts/setup-signing.sh` creates "SayMoore Self-Sign" identity in Keychain on first run.
- Re-running without `--force-regen` is a no-op (exit 0, message "cert exists, leaving alone").
- `xcodebuild -scheme SayMoore -configuration Release` produces a signed `.app` with zero strict-concurrency warnings.
- App appears as menu-bar icon, quits cleanly via menu.
- `.gitignore` excludes: `*.xcuserdata`, `build/`, `DerivedData/`, `*.p12`, `presets.json`, `history.jsonl`, `models/`, `.env*`, Sparkle private keys.

**Test plan:** Trivial scaffold tests; main verification is the build itself. Manual: build, run, quit, rebuild — confirm Accessibility permission persists in System Settings across rebuilds (this is the whole reason the signing identity must be stable).

### Slice 1 — Hotkey + audio capture
**Goal:** Ctrl-Ctrl starts/stops recording, writes 16kHz mono WAV to an app-private temp dir. Frontmost-app bundle ID is captured inside `HotkeyService` at the first Ctrl keydown.

**Deliverables:**
- `HotkeyService` with adapter-based design
  - CGEventTap detection of Ctrl-Ctrl with strict recognizer:
    - Ctrl down → Ctrl up with no other key event in between
    - Second Ctrl down within 300ms of first up
    - Any intervening key cancels the sequence
  - On first Ctrl keydown of a recognized double-tap, captures `NSWorkspace.shared.frontmostApplication?.bundleIdentifier` (with assertion that it is not SayMoore's own bundle ID; on collision, fall back to most recent non-self frontmost)
  - Esc-during-recording handler that fires **only when `AppState == .recording`**
- `AudioRecorder` — AVAudioEngine + AVAudioConverter to 16kHz mono float32, lock-free ring buffer, WAV export
- `MenuBarController` with idle/recording icons
- Audio temp file written under `~/Library/Caches/SayMoore/recordings/` with directory mode 0700, file mode 0600 (no `/tmp/` exposure)

**Acceptance:**
- Ctrl-Ctrl starts; menu icon switches to recording variant. Ctrl-Ctrl again stops.
- Esc during recording cancels (no file written, soft sound). Esc when not recording passes through to focused app untouched (verified in TextEdit).
- Captured bundle ID logged on each press; never equals `com.seemoretmoore.saymoore`.
- WAV file is valid 16kHz mono PCM, plays in QuickTime.
- Re-press during {transcribing, cleaning, pasting} blocked with busy tone (when those states exist; for now, no-op since they don't).
- Recognizer rejects: Ctrl-A then Ctrl-E (intervening A/E keys cancel sequence); Ctrl held down without release; gap >300ms between taps.

**Test plan (TDD):**
- Pure unit tests on `HotkeyRecognizer` fed synthetic key event streams: positive double-tap, intervening key, gap-too-long, modifier-other-than-Ctrl.
- `AudioRecorder.formatConverter` unit-tested with synthetic buffer.
- `BundleIDCapture` unit-tested with a fake `WorkspaceProvider` that returns SayMoore (must fall back to "previous").
- Manual: real hotkey press, real audio. Document in `docs/manual-tests/slice-1.md` including 20-press false-activation log.

### Slice 1.5 — Whisper SwiftPM spike (timeboxed: 1 day)
**Goal:** De-risk Slice 2 by proving the in-process Whisper integration works before committing to it.

**Deliverables:**
- A throwaway target or branch that:
  - Adds `whisper.cpp` SwiftPM dependency (`https://github.com/ggerganov/whisper.cpp`)
  - Loads `ggml-large-v3-turbo.bin` once at startup, keeps in memory
  - Transcribes a known 16kHz mono WAV (test fixture) and prints the result
  - Confirms Metal backend is available and used
  - Confirms Silero VAD is exposed in the Swift API surface (or documents the C-only limitation)
- A 1-page `docs/spikes/whisper-spm.md` writeup: API surface, threading constraints, model load time, transcription latency on the fixture, VAD availability

**Acceptance (any one of):**
- ✅ SPM integration succeeds, transcription matches expected text within Whisper's normal error rate, VAD callable from Swift → proceed with Slice 2 as planned.
- ⚠️ SPM integration succeeds for transcription but VAD is C-only → proceed with Slice 2; revise Slice 5 to call into VAD via a thin C bridge or use a different VAD library.
- ❌ SPM integration fails or is unstable → fall back to **cold-subprocess `whisper-cli` per dictation** for v1. Accept the ~1.5s model-load overhead; long-running warm-helper subprocess is v1.1 work. Tracy approves the fallback before Slice 2 begins. Revise Slice 2 deliverables only minimally (subprocess invocation + parse stdout) — no IPC, no helper lifecycle management in v1.

**Test plan:** the spike itself is the test. No unit tests; output is the writeup + decision.

**[CHECKPOINT]** before moving to Slice 2, regardless of outcome.

### Slice 2 — Pipeline coordinator + transcription + paste-with-integrity
**Goal:** After Ctrl-Ctrl-stop, transcript pasted verbatim into focused app via clipboard + Cmd+V, with all integrity checks. No cleanup, no preset.

**Deliverables:**
- `PipelineCoordinator` fully wired: `recording → transcribing → (passthrough) → pasting → idle`
- `TranscriptionService` (per Slice 1.5 outcome: in-process or subprocess)
- Whisper model bootstrap: `ModelDownloader` with HTTP Range resume + `.download-in-progress` sentinel + SHA256 verification (hash hardcoded in app binary), progress sheet
- `PasteService` with **changeCount sentinel** and **paste-time focus re-check**:
  ```
  let beforeCount = pasteboard.changeCount
  let savedItems = pasteboard.pasteboardItems
  pasteboard.clearContents()
  pasteboard.setString(transcript, forType: .string)
  let writtenCount = pasteboard.changeCount

  // Verify focus hasn't changed since recording started
  let currentFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
  if currentFrontmost != capturedBundleID {
      throw SayMooreError.pasteFocusChanged(captured: capturedBundleID, current: currentFrontmost)
      // (transcript is already on clipboard; user can paste manually)
  }

  postCmdVKeyEvent()

  try await Task.sleep(nanoseconds: 200_000_000)  // 200ms tuned default

  // Restore only if no other process has touched the clipboard
  if pasteboard.changeCount == writtenCount {
      pasteboard.clearContents()
      // restore savedItems
  } else {
      throw SayMooreError.pasteClipboardContended
      // (don't clobber whatever wrote after us; leave SayMoore's transcript? No — at this point
      // some other process owns the clipboard; we step back, don't clear, log warning)
  }
  ```
  Log a warning if the 200ms is exceeded by the system (clock-skew / thermal-throttle observability).
- Full state machine with error transitions for transcription and paste failures.

**Acceptance:**
- First launch: model download sheet appears, completes, sentinel removed only after SHA256 passes.
- Subsequent launches: model loaded into memory at app-start.
- Dictate "hello world", text appears in focused field.
- **Focus-change test:** start recording in TextEdit, Cmd-Tab to a different app while transcription runs → notification "Focus changed — paste manually", transcript on clipboard, no paste fired into the wrong app.
- **Clipboard-contention test:** during the 200ms restore window, write to clipboard from another process via `osascript -e 'set the clipboard to "interloper"'` → SayMoore detects contention, doesn't clobber, logs warning, fires notification.
- Captured bundle ID flows from `HotkeyService` through `PipelineCoordinator` to `PasteService`.

**Test plan (TDD):**
- `TranscriptionService.parseResult` unit-tested with canned outputs.
- `PasteService.orchestrate` unit-tested with `FakePasteboardAdapter` and `FakeKeyboardAdapter` — verifies orchestration order. Test is labeled `OrchestrationOrderTests`, not correctness — the actual race is not testable in unit tests, documented inline.
- `PasteService.changeCountSentinelLogic` unit-tested with synthetic changeCount sequences.
- `ModelDownloader` resume + sentinel logic unit-tested with `URLProtocolMock` and a tempdir.
- `PipelineCoordinator` happy path + each error transition unit-tested with fake services.
- Manual: focus-change scenario; clipboard-contention scenario; full pipeline into TextEdit/Slack/Mail/Xcode.

### Slice 3 — Default cleanup preset via Ollama
**Goal:** Transcript runs through Qwen 2.5 7B with the default light-cleanup prompt before paste.

**Deliverables:**
- `CleanupService` (URLSession to `localhost:11434/api/generate`, 10s timeout with fallback to raw transcript + notification, all paths produce a `SayMooreError` on failure that `PipelineCoordinator` translates to "use raw transcript")
- Ollama health probe at app launch (`GET /api/tags`)
- `presets.example.json` shipped with default preset only
- `PresetStore` minimal (load default, no overrides yet)
- `PipelineCoordinator` extended: `transcribing → cleaning → pasting` (cleaning between, no refactor of prior code)

**Acceptance:**
- Dictate "uh so like I think we should ship Friday um" → paste = "I think we should ship Friday."
- Ollama not running: notification "Ollama not reachable. Pasting raw transcript." Raw transcript still pastes (and goes through paste-integrity checks).
- Ollama running, model not pulled: notification with `ollama pull qwen2.5:7b-instruct`. Raw transcript pastes.
- Cleanup hangs >10s: timeout, raw transcript pastes, notification.

**Test plan (TDD):**
- `CleanupService.buildRequestBody` unit-tested: prompt assembly, model name, options.
- `CleanupService.parseResponse` unit-tested with canned Ollama responses.
- Timeout logic unit-tested with `URLSessionMock`.
- `PipelineCoordinator` extended-pipeline tests with cleanup happy-path, timeout, unreachable.
- Manual: 10 representative phrases, tune prompt, document iterations.

### Slice 4 — Per-app preset overrides
**Goal:** Slack, Mail, Xcode, Notes, Messages each get tailored cleanup. JSON file hot-reloads even when edited by real editors.

**Deliverables:**
- `AppContextService.resolveBundleID` (already wired through pipeline since Slice 1)
- `PresetStore` full implementation:
  - Override resolution by bundle ID
  - **App-support directory creation:** at first launch, ensure `~/Library/Application Support/SayMoore/` exists (mode 0700) **before** arming any file watcher. The directory-create-then-arm sequence is explicit; FSEventStream cannot arm on a non-existent path.
  - Hot-reload via `FSEventStream` watching the parent directory (`~/Library/Application Support/SayMoore/`), filtering for events on `presets.json` — handles atomic temp-rename writes correctly
  - On load failure, log error, fall back to last-good config + notification
- `presets.example.json` populated with default + 5 overrides
- On first launch, copy `presets.example.json` → `presets.json` if absent

**Acceptance:**
- Dictate in Slack: casual tone, lowercase "i", emoji-friendly.
- Dictate in Mail: greeting/sign-off polish.
- Dictate in Xcode: code-context awareness (preserve identifiers, technical terms).
- Edit `presets.json` in Xcode/VSCode while app running, save → next dictation uses new prompt without restart. **This is the failure mode the FSEventStream design fixes.**
- Malformed JSON: notification "presets.json invalid, using last-good config".

**Test plan (TDD):**
- `PresetStore.resolvePreset(for:)` pure-function tests.
- File-watch integration test: temp dir, atomic rename simulation, verify reload fires.
- Manual: dictate same phrase in each of 5 apps; edit JSON via VSCode (atomic rename); verify hot-reload.

### Slice 5 — VAD + length cap + warnings
**Goal:** Recording auto-stops on silence and at hard cap.

**Deliverables:**
- `VADBackend` protocol with `SileroVADBackend` real implementation (or fallback per Slice 1.5 outcome) and `FakeVADBackend` for tests
- `VADService` runs backend on rolling audio buffer windows; counts consecutive silence frames; auto-stops at 10s of silence
- 80s warning notification, 90s hard-stop notification

**Acceptance:**
- Speak 5s, stay silent 10s → auto-end, transcribe begins.
- Speak through 80s → notification "10 seconds remaining". At 90s → force-stop with notification.
- Esc still cancels at any point during recording.

**Test plan (TDD):**
- Silence-frame counter logic tested via `FakeVADBackend` returning canned silence/speech sequences.
- 90s cap and 80s warning timer logic unit-tested with a fake clock.
- Manual: speak/silence cycles; full 90s monologue.

### Slice 6 — Polish UI: pulse + sounds + cursor indicator + recording HUD
**Goal:** Multi-channel feedback: menu bar, sound, cursor indicator, **and a hard-to-miss HUD on the active display**.

**Deliverables:**
- Menu bar pulse animation during recording
- `start.aiff`/`stop.aiff`/`cancel.aiff`/`busy.aiff`
- `CursorIndicator` — static at hotkey-press position
- **`RecordingHUD`** — borderless `NSWindow` at `.floating` level on the active display (the display containing the focused app's main window), shows "● Recording" with a subtle pulse, fades in over 80ms, fades out on stop. Handles fullscreen apps (uses `.canJoinAllSpaces` and `.fullScreenAuxiliary` collection behavior).
- **Per-preset indicator on recording start.** The `RecordingHUD` shows the active preset/app name in small text below the pulse dot — e.g. "● Recording — Slack preset" or "● Recording — default". Briefly visible (~1.2s) then collapses to just the dot to reduce visual noise during longer dictations.

**Acceptance:**
- Recording starts: ping sound, menu icon pulses, cursor indicator appears, **HUD appears on active display**.
- Recording stops: stop sound, indicators fade.
- Cancel (Esc): cancel sound, indicators fade, no paste.
- Re-press during processing: busy sound.
- Fullscreen Xcode on second display: HUD appears on **second display**, not on the menu bar's display.
- HUD does not steal focus, does not block clicks, does not appear in screenshots inadvertently (verify via Cmd-Shift-4).

**Test plan:**
- Snapshot tests on `MenuBarController` icon-state mapping.
- Manual UI verification with screenshots in `docs/manual-tests/slice-6.md`. Fullscreen second-display scenario explicitly tested.

### Slice 7 — History log
**Goal:** Rolling 50-entry JSONL log of all dictations, accessible from menu.

**Deliverables:** `HistoryStore` (atomic JSONL append, rolling cap, schema version field), "Open Debug Log in Finder" menu item — explicitly labeled "Debug Log" in v1 to set expectations.

**Filesystem hardening:**
- App-support directory created with mode `0700`
- `history.jsonl` written with mode `0600`
- Directory name suffixed `.noindex` if Spotlight exclusion isn't otherwise honored (verify behavior); set `URLResourceKey.isExcludedFromBackupKey = true` on the directory
- All paths obtained via `FileManager` (no hard-coded `~/...` strings)

**Acceptance:**
- Each dictation appends one line with all fields.
- File caps at 50 lines (oldest evicted, FIFO).
- "Open Debug Log in Finder" reveals the file.
- Concurrent appends safe.

**Test plan (TDD):**
- `HistoryStore.append` unit-tested for cap eviction.
- Schema serialization roundtrip test.
- Concurrent-write test.
- Manual: 60 dictations, verify exactly 50 lines.

### Slice 8 — Garbage detection
**Goal:** Don't paste empty/garbage transcripts.

**Deliverables:** `TranscriptionService.isGarbage` predicate, `transcribing → error(.transcriptionGarbage)` transition wired, notification "No speech detected".

**Acceptance:**
- Hit hotkey, stay silent, hit hotkey → notification, no paste.
- Real speech with `no_speech_prob` near boundary still pastes.

**Test plan (TDD):**
- `isGarbage` pure-function test with synthetic prob arrays.
- Manual: hotkey + silence; hotkey + speech; hotkey + background noise.

### Slice 9 — Recovery handlers + watchdog + notification coalescing
**Goal:** Every failure path produces a clear notification and either recovers or surfaces actionable fix instructions. No notification storms.

**Deliverables:**
- `NotificationCoordinator` — coalescing per error class (60s cooldown), menu-bar status badge for persistent conditions
- 30s global watchdog in `PipelineCoordinator`
- Failure paths covered:
  - Ollama down → cold-spawn `ollama serve`, fallback to raw transcript with notification
  - Mic permission revoked mid-session → notification with "Open Privacy Settings" deeplink
  - Cleanup hangs >10s → timeout, raw transcript, notification
  - Paste focus-changed / clipboard-contended / injection-failed → leave on clipboard, notification
  - Whisper model corrupted (SHA256 mismatch on load) → re-download prompt with progress sheet
  - Disk full while writing history.jsonl → notification, drop entry, continue
  - Watchdog timeout → force-reset to idle, notification
  - **Audio device change mid-recording** (USB mic unplugged, Bluetooth mic disconnected, output device routed) → AVAudioEngine `configurationChange` notification handled: if state is `.recording`, abort gracefully with `error(.audioEngineFailed)`, surface "Audio device changed — recording stopped" notification, return to idle.
  - **Quit while non-idle** (Cmd-Q): in `.recording`, show confirmation alert "Discard current dictation and quit?"; in `.transcribing`/`.cleaning`, show transient "Finishing…" status and grant up to 5s for completion before forcing quit.
- `docs/error-recovery.md` catalog

**Acceptance:**
- Each scenario manually triggered, behavior verified, no app crash.
- Each notification has actionable text.
- Storm test: kill Ollama, then attempt 5 dictations within 60s → exactly 1 notification fires; menu-bar badge persists.

**Test plan (TDD):**
- `CleanupService` timeout unit-tested.
- `PasteService` failure-fallback unit-tested.
- `NotificationCoordinator` cooldown logic unit-tested with fake clock.
- `PipelineCoordinator` watchdog unit-tested with fake clock.
- Manual matrix: kill Ollama, revoke mic, fill disk, corrupt model, force watchdog. Document each.

### Slice 10 — First-run permissions wizard
**Goal:** New user is walked through Mic, Accessibility, Input Monitoring, Notifications.

**Deliverables:** SwiftUI `PermissionsWizard` with 4 steps, each with deeplink to Settings pane, **plus a fallback "I opened Settings myself" button** for cases where deeplinks fail (macOS deeplink reliability is version-dependent). Wizard re-checks on window-focus, advances automatically on grant. Blocks app entry until Mic + Accessibility + Input Monitoring granted; Notifications skippable.

**Acceptance:**
- Fresh user account: wizard appears.
- Each deeplink opens correct Settings pane (when working) or prints fallback instruction.
- Permissions revoked later: re-launching surfaces wizard.
- Wizard handles user closing Settings without granting (re-check on next focus).

**Test plan:**
- Permission-status detection unit-tested via adapter mocks.
- Manual: fresh user account, full walkthrough; revoke each permission and verify wizard re-surfaces.

### Slice 11 — Sparkle integration + release pipeline
**Goal:** In-app "Check for Updates" works; v0.9 → v1.0 update works on a clean install.

**Deliverables:** Sparkle 2 SwiftPM integration, `Info.plist` keys (`SUFeedURL`, `SUPublicEDKey`), `appcast.xml` template, `scripts/build-release.sh` (archive, sign, zip, EdDSA-sign reading from Keychain), `scripts/publish-release.sh` (update appcast.xml, push to GitHub Release).

**Acceptance:**
- Build v0.9, install, launch.
- Build v1.0, run `publish-release.sh` → GitHub Release created, appcast updated.
- v0.9 instance "Check for Updates" finds v1.0, downloads, verifies EdDSA, restarts.
- Tampered binary fails signature check.

**Test plan:**
- `appcast.xml` generation unit-tested.
- Manual: full v0.9 → v1.0 update on clean install.

### Slice 12 — README, screenshots, demo gif, QA pass, v1.0 tag
**Goal:** Strangers can install and use SayMoore from the README.

**Deliverables:** README with install, one-time setup (Ollama install + `ollama pull`, signing script), permissions, hotkey, presets editing, troubleshooting. Screenshots, demo gif. Stress-test pass: 50 consecutive dictations + Instruments memory snapshot.

**Acceptance:**
- README walkthrough followed by Tracy on a second account / fresh install: working in ≤5 min.
- 50 dictations: no crashes, RAM stable (±50MB), file handles stable.
- No `// TODO` / `// FIXME` left in main without a corresponding issue.
- All four permissions revoke/grant cycle tested.
- v1.0 tag pushed.

---

## Critical files to create

```
SayMoore.xcodeproj                                            (new project, strict-concurrency=complete)
SayMoore/App/SayMooreApp.swift                                @main
SayMoore/App/AppDelegate.swift                                lifecycle
SayMoore/App/AppState.swift                                   @MainActor state machine (state-only)
SayMoore/App/PipelineCoordinator.swift                        @MainActor pipeline orchestrator + watchdog
SayMoore/Core/Errors.swift                                    SayMooreError enum
SayMoore/Core/Logging.swift                                   Logger categories
SayMoore/Services/HotkeyService.swift                         CGEventTap, recognizer, frontmost capture
SayMoore/Services/AudioRecorder.swift                         AVAudioEngine, ring buffer
SayMoore/Services/VADService.swift                            wraps VADBackend
SayMoore/Services/VADBackend.swift                            protocol + Silero impl + Fake impl
SayMoore/Services/TranscriptionService.swift                  whisper.cpp (warm, actor-serialized)
SayMoore/Services/CleanupService.swift                        Ollama HTTP
SayMoore/Services/PasteService.swift                          changeCount sentinel + focus re-check
SayMoore/Services/AppContextService.swift                     bundle ID helpers
SayMoore/Services/PresetStore.swift                           JSON + FSEventStream on parent dir
SayMoore/Services/HistoryStore.swift                          rolling JSONL
SayMoore/Services/PermissionsManager.swift                    TCC checks
SayMoore/Services/ModelDownloader.swift                       Range + sentinel + SHA256
SayMoore/Services/NotificationCoordinator.swift               coalescing + badge
SayMoore/UI/MenuBarController.swift                           NSStatusItem + error badge
SayMoore/UI/CursorIndicator.swift                             borderless NSWindow at press position
SayMoore/UI/RecordingHUD.swift                                borderless NSWindow on active display
SayMoore/UI/SoundEffects.swift                                NSSound
SayMoore/UI/PermissionsWizard.swift                           SwiftUI flow + deeplink fallbacks
SayMoore/Resources/presets.example.json                       defaults + 5 overrides
SayMoore/Resources/{start,stop,cancel,busy}.aiff
SayMoore/Resources/Info.plist
SayMooreTests/                                                XCTest target
scripts/setup-signing.sh                                      idempotent
scripts/setup-sparkle-key.sh                                  generate + store EdDSA key in Keychain
scripts/build-release.sh                                      archive + sign + EdDSA + zip
scripts/publish-release.sh                                    appcast + GH release
docs/PRD.md                                                   (this file, post-approval)
docs/ARCHITECTURE.md                                          deeper diagrams
docs/spikes/whisper-spm.md                                    Slice 1.5 writeup
docs/manual-tests/slice-{1..12}.md
docs/error-recovery.md                                        Slice 9 catalog
.gitignore
LICENSE                                                       MIT
README.md
```

---

## Verification (end-to-end)

After all slices ship:

1. **Fresh-install walkthrough.** New macOS user account: download → README → first dictation. Target ≤5 min.
2. **Latency benchmark.** 20 prerecorded clips of varying length (5s, 15s, 30s). Avg ≤3.0s for ≤30s clips.
3. **Stress test.** 50 consecutive dictations. Instruments leak check. Zero leaks, RAM ±50MB stable.
4. **Permission revoke/re-grant.** Each permission, revoked then re-granted. App surfaces wizard cleanly without crash.
5. **Failure injection matrix.** Kill Ollama, revoke mic mid-recording, corrupt model, fill disk, force watchdog. Each surfaces a notification and recovers or instructs.
6. **Sparkle update.** v0.9 → v1.0 on clean install.
7. **Per-preset quality check.** Same dictation in each of 5 apps; visually different, all faithful.
8. **Focus-change paste safety.** Start dictation, switch app mid-flight → notification fires, transcript on clipboard, no wrong-app paste.

---

## Open items / non-goals

**Deferred to v1.1+:**
- Settings pane (model picker, hotkey customization, preset editor UI)
- Manifest-driven model recommendations + update notifications
- Accessibility-tree text-context awareness (Tier 2)
- "Retry with different model" history action
- Optional 24h audio retention for re-transcribe-on-correction
- In-app searchable history viewer (v1 ships "Open Debug Log in Finder")

**Explicitly not v1:**
- Streaming transcription
- Multi-user support
- iCloud sync
- Custom voice activation (other than Ctrl-Ctrl)
- Non-English support beyond what `large-v3-turbo` provides natively

**Resolved during second-pass review (now folded into the slices above):**
- ✅ Notification coalescing — Slice 9, 60s cooldown per error class + menu-bar badge for persistent conditions
- ✅ Per-preset visible indicator — Slice 6, shown briefly in `RecordingHUD`
- ✅ Fast path for short utterances — locked decision: skip cleanup below 1.5s OR ≤3 words
- ✅ history.jsonl filesystem hardening — Slice 7: 0700 dir, 0600 file, `isExcludedFromBackup`
- ✅ Audio temp file in app-private dir — Slice 1: `~/Library/Caches/SayMoore/recordings/`
- ✅ Whisper SHA256 hardcoded — locked decision
- ✅ ModelDownloader sentinel — locked decision
- ✅ `SayMooreError` + Logger from Slice 0 — Slice 0 deliverables
- ✅ LSUIElement = true — Slice 0 deliverables
- ✅ Audio device change handling — Slice 9
- ✅ Quit while non-idle — locked decision + Slice 9
- ✅ FSEventStream directory-create sequencing — Slice 4
- ✅ Watchdog reset on each transition — Cross-cutting concerns
- ✅ Error state transition ownership — Cross-cutting concerns
- ✅ Slice 1.5 fallback path = cold subprocess for v1 — Slice 1.5
- ✅ PasteService bundleID-nil handling + string-only fidelity rule — locked decision

**Known architectural debt (acceptable for v1, address in v1.1):**
- `PipelineCoordinator` holds 11+ services and is the primary orchestrator. Acceptable god-object risk for v1; refactor to dependency-struct injection in v1.1 if it becomes painful.
- Multi-type clipboard fidelity restoration deferred (string-only for v1).
- Long-running warm-helper subprocess for Whisper (only relevant if Slice 1.5 takes the ❌ branch).

---

## Next actions on Tracy approval

1. Run a second-pass review (codex) against this revised PRD before any code is written.
2. Fold in items 12–19 (or revisions per second pass) and ship final PRD.
3. Move PRD to `docs/PRD.md` in the repo.
4. Initialize git repo at `/Users/tracy/tracy_ai_sandbox/saymoore`, push to `github.com/seemoretmoore/saymoore` (public, MIT, per locked decision).
5. Create GitHub Project board with one issue per slice, ordered, labeled, with acceptance criteria.
6. Begin **Slice 0** on Tracy's "approved, start Slice 0" message.
