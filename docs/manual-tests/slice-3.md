# Slice 3 — Manual Test Plan (Cleanup Prompt Tuning)

Goal: validate the default Ollama cleanup against the PRD tone target ("light cleanup, preserve voice") and iterate the prompt in `SayMoore/Services/PresetStore.swift` → `defaultPromptTemplate` until all 10 representative phrases pass.

## Setup

1. Ollama running with `qwen2.5:7b-instruct` pulled:
   ```
   curl -s http://localhost:11434/api/tags | jq '.models[].name'
   ```
2. Launch SayMoore. Confirm menu-bar mic icon appears (model `.ready`, hotkey armed).
3. Tail logs:
   ```
   log stream --predicate 'subsystem == "com.seemoretmoore.saymoore"' --info --debug
   ```
4. Open TextEdit as the paste target.

## Tone target (from PRD §66)

- Remove filler (uh, um, like, you know).
- Resolve obvious self-corrections (`X — no, Y` → `Y`).
- Fix punctuation and capitalization to natural written English.
- Preserve word choice and phrasing. **Do not rewrite for style.**
- Do not add information that was not dictated.

## Representative phrases (10)

For each phrase: Ctrl-Ctrl, speak verbatim, Ctrl-Ctrl, observe paste. Fill in raw and cleaned columns.

| # | Category | Spoken phrase | Raw transcript | Cleaned output | Pass? | Notes |
|---|---|---|---|---|---|---|
| 1 | Filler-heavy | "uh so like I think we should ship Friday um" | _(not captured)_ | I think we should ship Friday. | ✅ | Exact PRD acceptance match. |
| 2 | Self-correction | "let's meet at three — no, four — on Tuesday" | _(not captured)_ | Let's meet at four on Tuesday. | ✅ | Self-correction resolved cleanly. |
| 3 | Technical terms | "the FSEventStream watcher arms after mkdir on the application support directory" | _(not captured)_ | The FS event stream watcher arms after mkdir on the application support directory. | ✅ cleanup | Whisper heard "FS event stream" instead of "FSEventStream" — acoustic miss, not a cleanup failure. Cleanup correctly preserved Whisper output. |
| 4 | Short utterance (fast-path) | "yes" | _(not captured)_ | Yes. | ✅ | Fast-path; skipped Ollama. |
| 5 | Short utterance (fast-path) | "ok thanks" | _(not captured)_ | Okay, thanks. | ✅ | Fast-path. |
| 6 | Long, multi-sentence | "so the plan is to first finish slice three and then move to slice four which adds the per app presets and the hot reload via FS events" | _(not captured)_ | The plan is to first finish slice 3 and then move to slice 4, which adds the per-app presets and the hot reload via FS events. | ✅ | Good sentence structure, commas, "per-app" hyphenation. |
| 7 | Question | "do you think we should pull the gpt oss model or stick with qwen" | _(not captured)_ | Do you think we should pull the GPT OSS model or stick with Clem? | ✅ cleanup | Whisper misheard "Qwen" as "Clem" — acoustic miss. Cleanup added "?" correctly and preserved phrasing. |
| 8 | Proper nouns | "send this to seemoretmoore at example dot com via slack" | _(not captured)_ | Send this to seemoretmoore@example.com via Slack. | ✅ | Email assembled, "Slack" + "seemoretmoore" capitalized. |
| 9 | Numbers + units | "the timeout is ten seconds and the fast path threshold is three words" | _(not captured)_ | The timeout is 10 seconds and the fast path threshold is three words. | ✅ | "10"/"three" inconsistency matches what was dictated — PRD says preserve word choice. |
| 10 | Already clean | "Ship it." | _(not captured)_ | Ship it. | ✅ | Fast-path. |

## Prompt iterations

Log each prompt change as a diff against `PresetStore.defaultPromptTemplate`.

### Iteration 1 (baseline) — 2026-05-14
- Prompt: as of commit `e3793d0` (default).
- Phrases failing on cleanup tone target: **none.**
- Whisper-side misses (out of scope for this slice): #3 "FSEventStream" → "FS event stream"; #7 "Qwen" → "Clem". Addressed (if at all) via Whisper initial-prompt biasing in a post-v1 slice.
- **Result: no prompt change needed. Default prompt locked for v1.**

## Failure-mode smoke tests (PRD §Slice 3 Acceptance)

| # | Setup | Action | Expected |
|---|---|---|---|
| F1 | **Quit Ollama.app from the menu bar** (not `pkill` — the GUI supervisor respawns the helper). | Dictate any phrase. | Notification: "Ollama not reachable. Pasting raw transcript." Raw transcript pastes. **Verified 2026-05-14.** |
| F2 | `ollama cp qwen2.5:7b-instruct qwen-stash:latest && ollama rm qwen2.5:7b-instruct` | Dictate. | Notification mentions `ollama pull qwen2.5:7b-instruct`. Raw pastes. **Verified 2026-05-14.** Restore with `ollama cp qwen-stash:latest qwen2.5:7b-instruct && ollama rm qwen-stash:latest`. |
| F3 | Temporarily set `CleanupService.defaultTimeout = 0.1` (any real Ollama response exceeds it), rebuild, dictate, then revert to `10`. Exercises the same `cleanupTimedOut` → fallback-to-raw path as a real hang. | Dictate. | Timeout, raw transcript pastes, notification. **Verified 2026-05-14.** |

## Sign-off

- [x] All 10 phrases pass cleanup tone target (2026-05-14).
- [x] All 3 failure modes behave per PRD (F1/F2/F3 verified 2026-05-14).
- [x] Final prompt locked (no change from `e3793d0`).
- [x] Ready to start Slice 4 (per-app preset overrides).
