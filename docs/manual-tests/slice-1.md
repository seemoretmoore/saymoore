# Slice 1 — Manual Test Plan

Hotkey recognition + audio capture. Run after `bash scripts/build-release.sh` (or run from Xcode) on a Mac that has granted **Input Monitoring** and **Microphone** permissions to SayMoore.

## Setup

1. Build and launch SayMoore. Confirm menu-bar mic icon appears, no Dock icon, no Cmd-Tab entry.
2. Tail the log:
   ```
   log stream --predicate 'subsystem == "com.seemoretmoore.saymoore"' --info --debug
   ```
3. Watch the recordings dir:
   ```
   ls -la ~/Library/Caches/SayMoore/recordings/
   stat -f '%Sp %N' ~/Library/Caches/SayMoore/recordings/
   ```
   Expect directory mode `drwx------` (0700).

## Acceptance checks

| # | Action | Expected |
|---|--------|----------|
| 1 | Open TextEdit. Press **Ctrl-Ctrl**. | Menu icon switches to `mic.fill`. Log: `Ctrl-Ctrl toggle (bundleID=com.apple.TextEdit)`, `AudioRecorder started`. |
| 2 | Speak "hello world" for ~2s. Press **Ctrl-Ctrl** again. | Menu icon returns to `mic`. Log: `Recorded → …/rec-…wav`. |
| 3 | Open the WAV in QuickTime. | Plays back at 16 kHz mono with the spoken phrase audible. |
| 4 | `stat -f '%Sp %N' ~/Library/Caches/SayMoore/recordings/rec-*.wav` | File mode `-rw-------` (0600). |
| 5 | Press Ctrl-Ctrl, then press **Esc** while recording. | Menu icon returns to `mic`. No file written. Log: `Recording cancelled via Esc`. |
| 6 | With SayMoore idle, focus TextEdit and press **Esc**. | Esc passes through to TextEdit (no SayMoore log entry). |
| 7 | Press Ctrl, type `a`, release Ctrl, press Ctrl again within 200 ms. | No toggle fires (intervening key cancels). Log shows ctrl-down, then `pendingBundleID` cleared. |
| 8 | Hold Ctrl down for 1 s without pressing/releasing again. | No toggle fires. |
| 9 | Press Ctrl-Ctrl with a 500 ms gap between taps. | No toggle fires. |
| 10 | Press Ctrl-Ctrl while focused on **SayMoore’s own menu** (left-click status item, then Ctrl-Ctrl). | `bundleID` logged should never equal `com.seemoretmoore.saymoore` — falls back to previous non-self app. |

## False-activation log (20 presses)

Use SayMoore for ~20 minutes of normal typing without pressing Ctrl-Ctrl intentionally. Record any spurious `Ctrl-Ctrl toggle` log lines and the surrounding key sequence.

| # | Timestamp | Surrounding sequence | Spurious toggle? |
|---|-----------|----------------------|------------------|
| 1 |           |                      |                  |

Goal: 0 spurious activations across 20 minutes of mixed Ctrl-key shortcuts (Ctrl-A, Ctrl-E, Ctrl-Tab, etc.).
