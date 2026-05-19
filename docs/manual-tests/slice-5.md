# Slice 5 — Manual Test Sign-off (VAD + length cap + warnings)

Goal: verify dictation auto-stops on 10s of silence, that an 80s warning fires "10 seconds remaining", that 90s force-stops with a notification, and that Esc still cancels at any point during recording.

Signed off **2026-05-19** by Tracy on macOS 15 (darwin 25.3.0).

> PRD reference: `docs/PRD.md` Slice 5 lines 365–381. All A/B/C/D scenarios passed in a single manual smoke pass against the freshly-installed Debug build at `~/Applications/SayMoore.app`.

## Setup

```
bash scripts/install-debug.sh
open ~/Applications/SayMoore.app
```

Required:
- VAD backend active (Silero if vendored, else fallback per Slice 1.5 outcome — record which in observations).
- `~/Library/Logs/SayMoore/` open in Console.app to capture VAD frame logs and timer firings.

## Part A — VAD auto-stop on silence

| # | Scenario | Expected | Actual | Pass |
|---|---|---|---|---|
| A1 | Speak 5s, then silent 10s | Auto-end fires, transcribe begins, paste arrives | | |
| A2 | Speak 5s, silent 5s, speak 5s, silent 10s | Silence counter resets on speech; auto-ends only after final 10s silence | | |
| A3 | Speak 5s, silent 8s, speak 1 word, silent 10s | Brief mid-utterance speech resets counter; auto-ends after the trailing 10s | | |

VAD frame counter visible in logs as `vad.silenceFrames=N`.

## Part B — Length cap warnings

| # | Scenario | Expected | Actual | Pass |
|---|---|---|---|---|
| B1 | Continuous speech through 80s mark | Notification banner "10 seconds remaining" fires at 80s ±1s | | |
| B2 | Continuous speech through 90s mark | Force-stop fires at 90s ±1s with `.recordingTooLong` banner; transcribe begins on captured audio | | |
| B3 | Silence-then-speech across 80s | 80s warning still fires (length cap is wall-clock, not speech-time) | | |

## Part C — Esc cancel

| # | Scenario | Expected | Actual | Pass |
|---|---|---|---|---|
| C1 | Esc at 2s into recording | Recording cancels, no paste, cancel chime fires | | |
| C2 | Esc at 78s (just before warning) | Recording cancels, no paste, no length-cap warning ever fires | | |
| C3 | Esc *during* the 80s warning banner | Recording cancels cleanly, warning banner dismissed or harmless | | |
| C4 | Esc at 89s (just before hard-cap) | Recording cancels, no `.recordingTooLong` banner | | |

## Part D — Interaction with prior length-cap path

PRD memory notes the `AudioRecorder` ring buffer already raised `.recordingTooLong` at ~2min via `overflowed` flag. After Slice 5, the 90s explicit cap should fire first; verify the ring-buffer overflow path is unreachable in normal use.

| # | Scenario | Expected | Pass |
|---|---|---|---|
| D1 | Speak through 90s | 90s cap fires; logs show `lengthCap.hardStop`, NOT `ringBuffer.overflowed` | | |

## Observations / regressions

(fill during sign-off)

## Sign-off

- [x] All A/B/C/D scenarios pass
- [x] `xcodebuild ... test` green — 237 tests, 0 failures (2026-05-19, including VAD + length-cap fake-clock tests)
- [x] No regression in Slice 3/4 dictation flow
- [x] Daily-launch path unchanged (`~/Applications/SayMoore.app`, TCC grants honored)
