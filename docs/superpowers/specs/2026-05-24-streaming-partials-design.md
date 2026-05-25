# Streaming Partials for SayMoore — Design Spec

## Context

SayMoore today is fully record-then-transcribe: the user presses-and-holds the hotkey, speaks, releases, and waits for `whisper_full()` to return a single blocking transcript before anything is pasted. Competitor apps (Whispr Flow especially) ship "see-it-as-you-speak" streaming partials as their headline demo moment. The current absence of any in-flight feedback is the single biggest perceived-speed gap. This spec adds a streaming partial display in the existing Lifestream HUD, without changing the final-paste behavior.

**Constraints — locked decisions:**
- Glass-pill + Lifestream HUD aesthetic is preserved exactly. The partial text is purely additive inside the existing pill — same backdrop blur, same gradient bar treatment, same 4px-above-window-bottom anchor.
- Single whisper model for both partials and final (no two-pass / no faster-partial-model). The bundled model is `ggml-large-v3-turbo.bin` (~1.5 GB fp16); both partials and the final transcript use it.
- The final paste on hotkey release remains the **authoritative event**. Partials are advisory display only — they never paste during recording. (v1 explicitly excludes live-paste into the active app; that's tagged optional/future.)
- RAM-reduction work (model quantization, lazy unload) is **explicitly out of scope** and goes into its own separate spec.

## Architecture

### Display surface — HUD Layout B (selected)

Partial text appears **to the right of the waveform inside the same glass pill**, separated by a 1px hairline divider. The pill widens horizontally as text grows (with a max width — long partials truncate with an ellipsis on the leading edge so the most recent words are always visible). On hotkey release, the pill snaps back to waveform-only width during the cleanup→paste phase, then disappears as normal.

- Font: same system font + size as the existing pill text styling
- Committed words: full opacity, normal weight
- Active (still-revisable) tail: 0.85 opacity, italic — distinguishes "this might still change" from "this is locked"
- Truncation: ellipsis on the **leading** edge (oldest characters hidden first), keeping the latest words on screen

### Transcription engine — sliding window with commit point

Matches whisper.cpp's own `stream` example pattern.

- **Active window:** last 10 s of recorded audio
- **Re-inference interval:** every 1.5 s, run `whisper_full()` on the active window
- **Commit age:** words whose timestamp is older than 5 s of audio get "committed" — frozen in the display and dropped from active inference
- The displayed pill string is `<committedText> + " " + <activeTail>`. Only the active-tail portion changes between passes; committed words never revise.

CPU profile (`large-v3-turbo`, Apple Silicon): per-pass cost ~200–400 ms on a 10 s window. At the 1.5 s default interval, sustained CPU is approximately 15–25% of one core. **This must be empirically validated on Tracy's M2 Ultra before ship** — if real numbers exceed 30%, the default interval bumps to 2 s. The calibration result lives in the verification section below.

RAM impact of streaming itself is essentially zero — whisper's context size doesn't grow with audio length, and the rolling-window inference reuses the same context object. The additional 10 s active-audio buffer is ~640 KB.

### User-facing toggle — Settings ▸ General

A new segmented control: **"Streaming partials"** with three values:
- **Off** — current behavior (record → blocking transcribe → paste). For users who want zero CPU during recording.
- **Balanced** *(default)* — 1.5 s interval / 10 s window / 5 s commit
- **Responsive** — 0.75 s interval / 8 s window / 4 s commit (~25% sustained CPU)

Persisted to `UserDefaults` under a stable key (e.g. `streaming.partials.mode`). Read once at `PipelineCoordinator` init and on Settings-change notification.

## Components

### `StreamingTranscriber` *(new, in `SayMoore/Services/`)*

Owns the sliding-window inference loop. One instance per recording.

**Interface:**
- `init(transcription: WhisperTranscriptionService, mode: StreamingMode)` — receives the existing whisper service; reuses its already-loaded context.
- `func start(audioSource: AudioRingBuffer)` — begins polling the ring buffer on a `.userInitiated` Task. The audio source is the existing `AudioRecorder`'s ring buffer; no new buffer.
- `func stop() async` — cancels the inference loop and awaits any in-flight pass. Idempotent.
- `var onPartialUpdate: ((String) -> Void)?` — fires on the main actor with the current `<committedText> + " " + <activeTail>` string after each pass.

**Internal state:**
- `committedText: String` — frozen words from prior passes
- `committedAudioSampleOffset: Int` — sample index in the ring buffer past which audio is "old enough" to commit; advances by `mode.commitAdvanceSamples` (≈ 5 s × 16 kHz) per pass
- Task loop: every `mode.interval`, read samples from `[committedAudioSampleOffset, end)`, clamp to the last `mode.windowSamples`, run `whisper_full()`, parse segments, split into committed-vs-active based on whisper's per-segment timestamps, append committed segments to `committedText`, emit on `onPartialUpdate`.

**Concurrency:** the inference call must not race the final `transcribe()` call on hotkey release. `stop()` awaits the in-flight pass before returning; `PipelineCoordinator` then calls the existing `transcription.transcribe(samples:)` on the *full* recorded audio. The final transcript replaces the partial display.

### `RecordingHUDController` *(extend `SayMoore/UI/RecordingHUDController.swift`)*

Add:
- `partialText: NSTextField` lazily created alongside the waveform bars
- `func updatePartialText(committed: String, active: String)` — main-actor entry. Resizes pill width with an implicit Core Animation transition (existing CALayer infra); applies the committed-vs-active opacity treatment via attributed string.
- Auto-hide partial text when both strings are empty (i.e. mode = Off, or pre-first-partial).

The existing 12 RMS-driven bars are unchanged. The glass pill background, blur, and gradient sheen are unchanged. The only visual addition is the text and its hairline divider.

### `PipelineCoordinator` *(extend `SayMoore/PipelineCoordinator.swift`)*

- Read `StreamingMode` from `UserDefaults` at init; cache on settings-change notification.
- On `.idle → .recording` transition, if mode != Off: instantiate `StreamingTranscriber`, wire `onPartialUpdate` to `RecordingHUDController.updatePartialText`, call `streamingTranscriber.start(audioSource: recorder.ringBuffer)`.
- On `.recording → .transcribing` transition: `await streamingTranscriber.stop()`, then proceed with the existing `transcription.transcribe(samples:)` call exactly as today.
- New invariant: streaming inference NEVER fires `onFallback` / banner — partials are best-effort display only. Any error in `StreamingTranscriber` logs at `.error` and silently disables the partial display for that session. The final `transcribe()` is unaffected.

### `SettingsViewModel` *(extend)*

Add `streamingMode: StreamingMode` published property; wire to the General tab's segmented control. Persists to `UserDefaults`.

## Data flow

```
[ Hotkey Down ]
    ↓
PipelineCoordinator: .recording state
    ↓
AudioRecorder.start() — fills AudioRingBuffer (existing)
    ↓
StreamingTranscriber.start(audioSource: ringBuffer)
    ↓
Loop every 1.5 s:
    ↓
    Read [committedOffset, end) from ring buffer, clamp to last 10 s
    ↓
    whisper_full() on that slice
    ↓
    Parse segments → (committedAdditions, activeTail)
    ↓
    committedText += committedAdditions
    ↓
    onPartialUpdate(committedText, activeTail)
    ↓
    HUD displays inside glass pill, right of waveform
    ↓
[ Hotkey Up ]
    ↓
await StreamingTranscriber.stop() (awaits in-flight pass)
    ↓
PipelineCoordinator: .transcribing state
    ↓
WhisperTranscriptionService.transcribe(samples: fullRecording) ← unchanged
    ↓
Cleanup → Paste (existing pipeline, unchanged)
    ↓
HUD fade-out (existing)
```

## Error handling

- `StreamingTranscriber` failure → log + disable partial display for the session. Recording continues; final transcribe is unaffected.
- Hotkey release mid-inference → `stop()` awaits the in-flight pass (max ~400 ms). User perceives this as part of the normal record-to-transcribe handoff latency.
- Settings change during recording → applies on *next* recording. Mid-recording mode swap is not supported.
- Mode = Off path: `StreamingTranscriber` is never instantiated. Zero overhead; current behavior bit-for-bit identical.

## Testing

- **Unit:** `StreamingTranscriberTests` — feed canned 16 kHz mono float buffers, assert commit-vs-active split, assert committed text accumulates correctly across passes, assert `stop()` is idempotent and awaits in-flight work.
- **Integration:** extend the dogfood T1–T9 matrix with a T10 "streaming partial displays during 20 s dictation, final paste matches what the partial last showed (modulo cleanup pass)" check in TextEdit.
- **Empirical CPU calibration (REQUIRED before merge):** record three 60 s dictations on M2 Ultra with Balanced mode; capture Activity Monitor's per-process CPU. If sustained CPU > 30% on one core, bump the Balanced interval to 2 s and re-test.
- **Mode-Off regression:** assert that with Streaming = Off, recorder behavior is byte-for-byte identical to current main (no new task, no new ring-buffer reader, no perf delta).

## Files to modify

| File | Change |
|---|---|
| `SayMoore/Services/StreamingTranscriber.swift` *(new)* | Sliding-window inference loop, commit logic, `onPartialUpdate` callback |
| `SayMoore/UI/RecordingHUDController.swift` | Add `partialText` `NSTextField`, `updatePartialText()`, width animation; keep waveform unchanged |
| `SayMoore/PipelineCoordinator.swift` | Instantiate/start/stop `StreamingTranscriber` around recording state; wire HUD callback; read settings |
| `SayMoore/UI/SettingsView.swift` (General tab) | Add "Streaming partials" segmented control |
| `SayMoore/Services/SettingsViewModel.swift` | Publish `streamingMode`; persist to UserDefaults |
| `SayMooreTests/StreamingTranscriberTests.swift` *(new)* | Unit coverage |
| `docs/manual-tests/streaming-partials.md` *(new)* | T10 dogfood log + CPU calibration record |
| `docs/PRD.md` (or v1.2 candidates list) | Note streaming partials as v1.2 candidate post-merge |

## Reused components / patterns

- `AudioRingBuffer` (existing) — single audio source; no parallel buffer
- `WhisperTranscriptionService` whisper context (existing) — reused for partial passes, no second model load
- HUD glass-pill styling, blur, gradient bars (existing) — unchanged
- `PipelineCoordinator` state machine + callback pattern (existing) — `onPartialUpdate` follows the same shape as `onLengthCapPhase` / `onBusyHotkey`
- `SettingsViewModel` UserDefaults persistence pattern (existing) — mirrors `audio.feedback.muted`

## Out of scope (separate specs)

- **RAM reduction** — model quantization (fp16 → q5_0 on `ggml-large-v3-turbo.bin`, ~750 MB savings) and lazy model unload after idle. Highest-impact RAM lever in the codebase; deserves its own brainstorm + spec.
- **Live paste into active app** ("Layout F" hybrid from brainstorm) — text appearing in the focused app's input field as the user speaks. Optional future v2; gated on positive v1 reception.
- **Two-pass model strategy** (fast-partial-model + accurate-final-model) — explicitly rejected for v1 to keep RAM flat.
- **Per-app streaming opt-out via presets** — would let users disable streaming for specific bundle IDs. Defer until any in-the-wild complaint surfaces.

## Verification

1. Build + existing tests green.
2. Streaming = Off: T1–T9 dogfood matrix unchanged (proves no regression on the existing path).
3. Streaming = Balanced: 20 s dictation in TextEdit — partial text appears in HUD ≤ 2 s after first word, updates ~every 1.5 s, final paste matches what HUD last showed (allowing for cleanup pass).
4. Streaming = Responsive: same as #3 with faster cadence; verify pill widening animation doesn't flicker.
5. CPU calibration: Activity Monitor sustained CPU on M2 Ultra during a 60 s dictation in Balanced mode ≤ 30% on one core. Recorded in `docs/manual-tests/streaming-partials.md`.
6. Mid-recording mode change is ignored (applies next session).
7. Aesthetic confirmation: side-by-side screenshot of the HUD with streaming Off vs Balanced — glass pill, blur, bars unchanged; only text + divider added on the right.
