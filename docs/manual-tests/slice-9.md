# Slice 9 — Manual Test Matrix (Recovery + Watchdog + Coalescing)

Goal: prove SayMoore degrades gracefully under storms, hangs, hardware loss,
permission revocation, Cmd-Q during in-flight work, model corruption, and
Ollama cold-start. All copy is sourced from
`SayMoore/Services/NotificationCenterAdapter.swift`'s `message(for:)`; see
`docs/error-recovery.md` for the full mapping.

## 1. Notification coalescing storm

Verifies `NotificationCoordinator` dedupes within its 60s cooldown and raises
the persistent menu-bar badge.

1. From the Ollama menu-bar icon, choose **Quit Ollama**. (Note: `pkill ollama serve`
   is futile if `Ollama.app` is installed — the menu-bar agent will respawn it.)
2. Confirm `curl -sf http://127.0.0.1:11434/api/tags` returns connection refused.
3. Fire 5 dictations within 60 seconds against any app.
4. Expected:
   - Exactly **one** "Ollama not reachable" notification banner (further
     attempts are coalesced and logged as
     `NotificationCoordinator coalesced: ollamaUnreachable`).
   - Menu-bar badge shows **Ollama down** for the duration.
   - All five recordings still paste their raw transcripts (fallback works).

## 2. Watchdog timeout

The watchdog budget is **30s in release builds**, **0.2s in unit tests**.
Forcing it in a release build requires a hang.

1. Easiest reproduction: build with a debug flag that sleeps inside the
   transcription step (or temporarily stub whisper.cpp to sleep > 30s).
   Alternative: pull the LAN cable mid-cleanup against a remote Ollama so the
   HTTP call hangs past the watchdog budget.
2. Start a dictation and let it hang.
3. After 30s, expected:
   - State machine forces a reset to `.idle` (visible: HUD disappears, cursor
     indicator clears, hotkey responsive again).
   - Watchdog banner fires (currently the generic "SayMoore error" arm — see
     copy-gaps in `docs/error-recovery.md`).
   - No paste occurs.

## 3. Audio device change mid-recording

1. Plug in a USB or Bluetooth mic and select it as system input.
2. Start a dictation; speak for ~2 seconds.
3. Yank the cable (USB) or toggle Bluetooth off.
4. Expected:
   - Recording aborts cleanly (no crash, no stuck HUD).
   - Banner: **Audio engine failed** — *Could not start recording. Check
     audio devices and try again.*
   - State returns to `.idle`; subsequent dictation on the built-in mic works.

## 4. Mic permission revocation mid-session

1. Launch SayMoore, confirm a dictation works.
2. Open **System Settings → Privacy & Security → Microphone**, uncheck SayMoore.
3. Start a new recording with the hotkey.
4. Expected:
   - Banner: **Mic permission revoked** — *Recording stopped. Grant microphone
     access in System Settings → Privacy & Security → Microphone.*
   - Recording cancelled; state → `.idle`.
   - Persistent badge: **Permission revoked: microphone**.
   - Re-enabling permission clears the badge after the next successful
     recording (or via `clearBadge`).

## 5. Cmd-Q matrix

Verifies the in-flight quit handler.

| State | Action | Expected |
|---|---|---|
| Idle | Cmd-Q | App quits immediately. |
| Recording | Cmd-Q | Confirmation alert appears. **Cancel** → app keeps running, recording continues. **Discard & Quit** → recording discarded, app quits. |
| Transcribing | Cmd-Q | App waits up to 5s for the pipeline to drain (transcript → cleanup → paste), then quits. |
| Cleaning | Cmd-Q | App waits up to 5s for cleanup + paste to finish, then quits. |
| Pasting | Cmd-Q | App waits up to 5s for paste to complete, then quits. |

For each transcribe/clean/paste case: visually confirm the paste lands in the
focused app before the dock icon disappears.

## 6. Model corruption (bootstrap-time only)

1. Quit SayMoore.
2. Corrupt the model on disk:
   ```sh
   dd if=/dev/zero \
      of="$HOME/Library/Application Support/SayMoore/models/ggml-small.en.bin" \
      bs=1 count=10 conv=notrunc
   ```
3. Relaunch SayMoore.
4. Expected:
   - Banner: **Model corrupted** — *Restart SayMoore to re-download.*
   - Persistent badge: **Whisper model corrupted**.
   - Model re-download window appears; on completion, dictation resumes and
     badge clears.

**Caveat (out of scope for Slice 9):** corruption introduced *while the app is
running* will not surface as `.modelCorrupted` — integrity is only validated at
bootstrap. A future slice could add periodic re-validation.

## 7. Ollama cold-spawn

1. From the Ollama menu-bar icon, choose **Quit Ollama**.
2. Launch SayMoore (or trigger any dictation that requires cleanup).
3. `OllamaSupervisor` attempts to cold-spawn `ollama serve`.
4. After ~3s, `tags()` retries.
5. Expected behavior depends on environment:
   - **`Ollama.app` installed:** the menu-bar agent will usually have already
     respawned `ollama serve` before our supervisor's spawn — either way,
     `tags()` succeeds on the retry, cleanup runs, no banner.
   - **CLI-only install:** our supervisor-spawned `ollama serve` answers
     `tags()`; cleanup runs, no banner.
   - **Spawn fails entirely:** banner **Ollama not reachable** fires once,
     badge **Ollama down** lights up.
6. On any successful recovery, confirm the menu-bar badge clears (either
   automatically on the next successful dictation, or explicitly via
   `clearBadge`).

## Sign-off

- [ ] Storm test — single banner + persistent badge.
- [ ] Watchdog timeout resets to idle.
- [ ] Audio device unplug aborts gracefully with the expected banner.
- [ ] Mic-permission revoke cancels recording + raises persistent badge.
- [ ] Cmd-Q matrix behaves per the table above.
- [ ] Bootstrap-time model corruption surfaces correctly; caveat understood.
- [ ] Ollama cold-spawn recovers (or fails loudly) per environment.
