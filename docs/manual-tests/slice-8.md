# Slice 8 — Manual Test Sign-off (Garbage detection)

Goal: silent or hallucinated recordings produce a "No speech detected" notification and no paste. Real speech with near-boundary `no_speech_prob` still pastes.

> Built on PR #16's hallucination guard. PR #16 wired the predicate and the transition; this slice routes the transition through `onFallback` so the banner actually reaches the user, and extends the denylist with `i'm sorry` / `i'm sorry.` / `sorry.` (the literal Whisper-on-silence output seen during Slice 6 Bundle B smoke).

Signed off **TBD** on macOS \_\_\_ / \_\_\_.

## Setup

```
bash scripts/install-debug.sh
open ~/Applications/SayMoore.app
```

## Part A — Silence rejection

| # | Trigger | Expected | Actual | Pass |
|---|---|---|---|---|
| A1 | Ctrl-Ctrl, stay silent ~2 s, Ctrl-Ctrl | "No speech detected" banner; NO paste | | |
| A2 | Ctrl-Ctrl, stay silent until VAD auto-stop fires | "No speech detected" banner; NO paste | | |
| A3 | Ctrl-Ctrl with the mic muted (hardware), speak normally, Ctrl-Ctrl | "No speech detected" banner; NO paste (Whisper sees only noise floor) | | |

## Part B — Hallucination phrases rejected

Each scenario: trigger a recording short enough that Whisper falls back to a canned phrase (silent or near-silent capture). The transcript should NOT paste; banner appears.

| # | Reproduction hint | Expected | Actual | Pass |
|---|---|---|---|---|
| B1 | Silent recording — should not paste `Thank you.` | banner + no paste | | |
| B2 | Silent recording — should not paste `I'm sorry.` (Slice 6 regression) | banner + no paste | | |
| B3 | Silent recording — should not paste `Bye.` / `Thanks for watching.` | banner + no paste | | |

## Part C — Real speech preserved

| # | Scenario | Expected | Actual | Pass |
|---|---|---|---|---|
| C1 | "Hello world" — clear speech | Pastes "Hello world." or similar | | |
| C2 | "Yes" or "OK" — one-word utterance | Pastes the word | | |
| C3 | "I appreciate the review, thank you." — real sentence ending in a denylist phrase | Pastes in full (denylist is whole-utterance match) | | |
| C4 | Quiet but real speech ("hmm okay") near the noSpeechProb boundary | Pastes (no false-positive rejection) | | |

## Sign-off

- [ ] Parts A / B / C pass
- [ ] `xcodebuild ... test` green (TranscriptTests + PipelineCoordinatorTests garbage-onFallback assertion)
- [ ] No regression in PR #16's whole-utterance preservation behavior
