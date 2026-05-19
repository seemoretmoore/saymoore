# Slice 6 — Manual Test Sign-off (Pulse + HUD + cursor indicator)

Goal: verify multi-channel recording feedback — menu icon pulse, cursor indicator at press position, borderless HUD on active display with per-preset label, ping/stop/cancel/busy sounds — and that the HUD is non-intrusive (no focus steal, no click blocking, absent from screenshots).

> **Bundle A (2026-05-19): sounds + menu-bar pulse + length-cap pill — shipped, PR #18.**
> **Bundle B (2026-05-19): HUD window + cursor indicator + per-preset label — shipped this PR.** PRD reference: `docs/PRD.md` Slice 6 lines 383–403.

Signed off **TBD** on macOS \_\_\_ / \_\_\_.

## Setup

```
bash scripts/install-debug.sh
open ~/Applications/SayMoore.app
```

Required:
- Two displays (laptop + external) for the fullscreen-second-display scenario in Part D.
- Screenshot tool (Cmd-Shift-4) ready for Part E.
- `presets.json` materialized with the bundled Slack/BBEdit/Notes/Messages overrides (verify per-preset HUD label).

## Part A — Recording start feedback **[Bundle A]**

Trigger: Ctrl-Ctrl with frontmost = TextEdit (default preset).

| # | Channel | Expected | Actual | Pass |
|---|---|---|---|---|
| A1 | Sound | Glass chime plays once on start | | |
| A2 | Menu bar | Icon dims to ~50% half-tone (`appearsDisabled`) every 1 s; elapsed `M:SS` counter renders next to the icon and ticks each second | | |
| A3 | Cursor indicator | Translucent red ring appears at cursor position captured at Ctrl-Ctrl press time; fades in over ~80 ms | | |
| A4 | HUD | Borderless HUD appears top-center of active display ~40 px below the menu bar, showing `● Recording — default preset`; fades in over ~80 ms; red dot pulses | | |
| A5 | HUD label collapse | After ~1.2 s the label collapses to `● Recording` (preset name removed) | | |
| A6 | Pill at start | Green pill appears behind mic glyph immediately on `.recording` | | |
| A7 | Pill at ~60 s elapsed | Pill turns yellow (30 s remaining) | | |
| A8 | Pill at ~80 s elapsed | Pill turns red, concurrent with the "10 seconds remaining" banner | | |
| A9 | Pill clears on stop/cancel | Pill background gone; icon returns to plain template mic | | |

## Part B — Per-preset HUD label **[Bundle B]**

| # | App (frontmost) | Bundle ID | Expected HUD label | Actual | Pass |
|---|---|---|---|---|---|
| B1 | Slack | `com.tinyspeck.slackmacgap` | `● Recording — Slack preset` | | |
| B2 | BBEdit | `com.barebones.bbedit` | `● Recording — BBEdit preset` | | |
| B3 | Notes | `com.apple.Notes` | `● Recording — Notes preset` | | |
| B4 | Messages | `com.apple.MobileSMS` | `● Recording — Messages preset` | | |
| B5 | Safari (no override) | `com.apple.Safari` | `● Recording — default` | | |

## Part C — Stop / cancel / busy **[Bundle A]**

| # | Trigger | Expected | Actual | Pass |
|---|---|---|---|---|
| C1 | Ctrl-Ctrl again (stop) | Pop chime plays; menu icon pulse stops, alpha returns to 1.0 | | |
| C2 | Esc during recording (cancel) | Basso chime plays (deep "bonk", clearly distinct from Pop); pulse stops; counter clears; NO paste | | |
| C3 | Re-press Ctrl-Ctrl during `transcribing` state (busy) | Sosumi chime plays; no new recording starts; pipeline continues | | |
| C4 | Re-press Ctrl-Ctrl during `cleaning` / `pasting` state (busy) | Sosumi chime plays; pipeline continues | | |

## Part D — Active-display + fullscreen **[Bundle B]**

Setup: open Xcode fullscreen on the **external** display; menu bar lives on the **laptop** display.

| # | Scenario | Expected | Actual | Pass |
|---|---|---|---|---|
| D1 | Trigger dictation with Xcode fullscreen frontmost on external | HUD appears on **external** display (where Xcode is), NOT on laptop menu-bar display | | |
| D2 | HUD visibility above fullscreen | HUD renders above Xcode's fullscreen via `.canJoinAllSpaces` + `.fullScreenAuxiliary` | | |
| D3 | Active app on laptop (non-fullscreen) | HUD appears on laptop display | | |

## Part E — Non-intrusive guarantees **[Bundle B]**

| # | Property | Test | Expected | Actual | Pass |
|---|---|---|---|---|---|
| E1 | No focus steal | Trigger dictation while typing in BBEdit | Keystrokes continue to land in BBEdit, no focus jump | | |
| E2 | No click blocking | Click "through" the HUD location | Click reaches underlying app | | |
| E3 | Absent from screenshots | Cmd-Shift-4, select HUD region | Screenshot does NOT contain the HUD (`sharingType` exclusion) | | |
| E4 | No dock/cmd-tab presence | Cmd-Tab during recording | SayMoore not listed (or listed only as expected per existing behavior) | | |

## Part F — Sound mute interaction **[Bundle A]**

`AudioFeedbackService.muted` defaulted to false. With `defaults write com.seemoretmoore.saymoore audio.feedback.muted -bool true` then relaunch (mute is read once at init):

| # | Scenario | Expected | Actual | Pass |
|---|---|---|---|---|
| F1 | Muted recording start | No Glass chime; menu-bar icon still pulses | | |
| F2 | Muted stop | No Pop chime; pulse stops | | |
| F3 | Muted Esc cancel | No Basso chime; pulse stops; no paste | | |
| F4 | Muted busy press | No Sosumi chime; pipeline continues | | |

(Confirms the pulse is independent of the audio mute toggle.)

## Observations / regressions

(fill during sign-off)

## Sign-off

### Bundle A (this PR)

- [ ] All Bundle-A rows in Parts A / C / F pass (sounds + pulse only)
- [ ] `xcodebuild ... test` green (AudioFeedbackServiceTests + PipelineCoordinatorTests busy-hook)
- [ ] No regression in chime timing (Slice 6 minimal-subset shipped 2026-05-14)
- [ ] No regression in Slice 4 per-preset resolution

### Bundle B (this PR)

- [ ] Parts A3–A5 (cursor indicator + HUD window + label collapse)
- [ ] Part B (per-preset HUD label for Slack/BBEdit/Notes/Messages/default)
- [ ] Part D (active-display + fullscreen second display)
- [ ] Part E (no focus steal / no click block / absent from screenshots / no cmd-tab presence)
- [ ] `xcodebuild ... test` green (PresetDisplayNameTests + RecordingHUDControllerTests + ActiveDisplayResolverTests added)
