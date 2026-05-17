# Slice 6 — Manual Test Sign-off (Pulse + HUD + cursor indicator)

Goal: verify multi-channel recording feedback — menu icon pulse, cursor indicator at press position, borderless HUD on active display with per-preset label, ping/stop/cancel/busy sounds — and that the HUD is non-intrusive (no focus steal, no click blocking, absent from screenshots).

Signed off **TBD** on macOS \_\_\_ / \_\_\_.

> Skeleton stub written 2026-05-17 alongside Phase B prep. Fill in observations as `wt-slice6` lands. PRD reference: `docs/PRD.md` Slice 6 lines 383–403. Audio chimes already shipped via `AudioFeedbackService`; this slice adds the visual layer.

## Setup

```
bash scripts/install-debug.sh
open ~/Applications/SayMoore.app
```

Required:
- Two displays (laptop + external) for the fullscreen-second-display scenario in Part D.
- Screenshot tool (Cmd-Shift-4) ready for Part E.
- `presets.json` materialized with the bundled Slack/BBEdit/Notes/Messages overrides (verify per-preset HUD label).

## Part A — Recording start feedback

Trigger: Ctrl-Ctrl with frontmost = TextEdit (default preset).

| # | Channel | Expected | Actual | Pass |
|---|---|---|---|---|
| A1 | Sound | `start.aiff` ping plays | | |
| A2 | Menu bar | Icon pulses (subtle scale or opacity oscillation) | | |
| A3 | Cursor indicator | Static dot appears at the cursor position *at hotkey-press time* (does NOT follow cursor) | | |
| A4 | HUD | Borderless window fades in over ~80ms on active display, shows "● Recording — default" below dot | | |
| A5 | HUD label collapse | After ~1.2s, label collapses to just the "●" dot | | |

## Part B — Per-preset HUD label

| # | App (frontmost) | Bundle ID | Expected HUD label | Actual | Pass |
|---|---|---|---|---|---|
| B1 | Slack | `com.tinyspeck.slackmacgap` | `● Recording — Slack preset` | | |
| B2 | BBEdit | `com.barebones.bbedit` | `● Recording — BBEdit preset` | | |
| B3 | Notes | `com.apple.Notes` | `● Recording — Notes preset` | | |
| B4 | Messages | `com.apple.MobileSMS` | `● Recording — Messages preset` | | |
| B5 | Safari (no override) | `com.apple.Safari` | `● Recording — default` | | |

## Part C — Stop / cancel / busy

| # | Trigger | Expected | Actual | Pass |
|---|---|---|---|---|
| C1 | Ctrl-Ctrl again (stop) | `stop.aiff` plays; menu icon settles; cursor + HUD fade out | | |
| C2 | Esc during recording (cancel) | `cancel.aiff` plays; indicators fade; NO paste | | |
| C3 | Re-press Ctrl-Ctrl during `transcribing` state (busy) | `busy.aiff` plays; HUD remains in transcribing state; no new recording starts | | |

## Part D — Active-display + fullscreen

Setup: open Xcode fullscreen on the **external** display; menu bar lives on the **laptop** display.

| # | Scenario | Expected | Actual | Pass |
|---|---|---|---|---|
| D1 | Trigger dictation with Xcode fullscreen frontmost on external | HUD appears on **external** display (where Xcode is), NOT on laptop menu-bar display | | |
| D2 | HUD visibility above fullscreen | HUD renders above Xcode's fullscreen via `.canJoinAllSpaces` + `.fullScreenAuxiliary` | | |
| D3 | Active app on laptop (non-fullscreen) | HUD appears on laptop display | | |

## Part E — Non-intrusive guarantees

| # | Property | Test | Expected | Actual | Pass |
|---|---|---|---|---|---|
| E1 | No focus steal | Trigger dictation while typing in BBEdit | Keystrokes continue to land in BBEdit, no focus jump | | |
| E2 | No click blocking | Click "through" the HUD location | Click reaches underlying app | | |
| E3 | Absent from screenshots | Cmd-Shift-4, select HUD region | Screenshot does NOT contain the HUD (`sharingType` exclusion) | | |
| E4 | No dock/cmd-tab presence | Cmd-Tab during recording | SayMoore not listed (or listed only as expected per existing behavior) | | |

## Part F — Sound mute interaction

`AudioFeedbackService.muted` defaulted to false. With `defaults write com.seemoretmoore.saymoore audio.feedback.muted -bool true`:

| # | Scenario | Expected | Actual | Pass |
|---|---|---|---|---|
| F1 | Muted recording start | No `start.aiff`; visual indicators (pulse + cursor + HUD) still appear | | |
| F2 | Muted stop | No `stop.aiff`; visuals fade | | |

(Confirms visuals are independent of the audio mute toggle.)

## Observations / regressions

(fill during sign-off)

## Sign-off

- [ ] All A–F scenarios pass
- [ ] `xcodebuild ... test` green (including `MenuBarController` icon-state snapshot tests)
- [ ] No regression in chime timing (Slice 6 minimal-subset shipped 2026-05-14)
- [ ] No regression in Slice 4 per-preset resolution
