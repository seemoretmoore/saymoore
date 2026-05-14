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
| 1 | Filler-heavy | "uh so like I think we should ship Friday um" | | | | PRD acceptance example → "I think we should ship Friday." |
| 2 | Self-correction | "let's meet at three — no, four — on Tuesday" | | | | Expect: "Let's meet at four on Tuesday." |
| 3 | Technical terms | "the FSEventStream watcher arms after mkdir on the application support directory" | | | | Identifiers preserved verbatim. |
| 4 | Short utterance (fast-path) | "yes" | | | | Word count ≤3 → skips Ollama, pastes raw. |
| 5 | Short utterance (fast-path) | "ok thanks" | | | | Fast-path. |
| 6 | Long, multi-sentence | "so the plan is to first finish slice three and then move to slice four which adds the per app presets and the hot reload via FS events" | | | | Expect sentence breaks + capitalization. |
| 7 | Question | "do you think we should pull the gpt oss model or stick with qwen" | | | | Question mark, "GPT-OSS"/"Qwen" capitalization is a judgment call — preserve dictated form. |
| 8 | Proper nouns | "send this to tracy at clinical pattern dot com via slack" | | | | "Tracy", "Slack" capitalized; email left as dictated. |
| 9 | Numbers + units | "the timeout is ten seconds and the fast path threshold is three words" | | | | Number/word form preserved. |
| 10 | Already clean | "Ship it." | | | | Should pass through unchanged. |

## Prompt iterations

Log each prompt change as a diff against `PresetStore.defaultPromptTemplate`.

### Iteration 1 (baseline)
- Prompt: as of commit `e3793d0` (default).
- Phrases failing: _fill in_
- Hypothesis for next change: _fill in_

### Iteration 2
- Change: _fill in_
- Phrases now passing: _fill in_
- Phrases regressed: _fill in_

_(Add iterations as needed.)_

## Failure-mode smoke tests (PRD §Slice 3 Acceptance)

| # | Setup | Action | Expected |
|---|---|---|---|
| F1 | `pkill -f "ollama serve"` | Dictate any phrase. | Notification: "Ollama not reachable. Pasting raw transcript." Raw transcript pastes. |
| F2 | `ollama cp qwen2.5:7b-instruct qwen-stash && ollama rm qwen2.5:7b-instruct` | Dictate. | Notification mentions `ollama pull qwen2.5:7b-instruct`. Raw pastes. Restore with `ollama cp qwen-stash qwen2.5:7b-instruct`. |
| F3 | Point `CleanupService` URL at a sleep proxy (or `tc` / Network Link Conditioner) so request hangs >10s. | Dictate. | After 10s: timeout, raw transcript pastes, notification. |

## Sign-off

- [ ] All 10 phrases pass.
- [ ] All 3 failure modes behave per PRD.
- [ ] Final prompt committed.
- [ ] Ready to start Slice 4 (per-app preset overrides).
