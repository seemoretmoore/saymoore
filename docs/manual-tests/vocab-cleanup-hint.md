# Custom vocabulary (cleanup-LLM glossary) — manual test

Verifies that the v1.1 Custom Dictionary feature corrects acoustic misses on
project-specific identifiers without regressing common-English transcription.

> **Mechanism note (2026-05-15):** Vocabulary is injected as a "Known technical
> terms" glossary line into the Ollama cleanup prompt, above the `<transcript>`
> fence. The cleanup LLM does the camelCase recovery; whisper's `initial_prompt`
> is no longer used for biasing (it cannot fuse phonetic chunks). The user-facing
> behavior is unchanged — `vocabulary` array in `presets.json`, same bounds,
> same banner pattern. See the spec's "Superseded-mechanism note" for context.

## Setup

1. `bash scripts/install-debug.sh && open ~/Applications/SayMoore.app` — daily-launch.
2. Edit `~/Library/Application Support/SayMoore/presets.json` (or use the menu
   bar "Edit Presets…" item to reveal it in Finder). Add a top-level key:

   ```json
   "vocabulary": ["FSEventStream", "Qwen", "AVAudioEngine"]
   ```

3. Save. The `PresetWatcher` (FSEvents) hot-reloads within ~100 ms; the next
   dictation uses the new vocab. No restart needed.

## Regression phrases (must still transcribe correctly)

Dictate each and check the pasted output. From Slice 3 baseline:

- F1 — *"hi tracy, i think we should ship friday and also fix the api timeout"*
- F2 — *"add a unit test for the cleanup service"*
- F3 — *"the meeting is at three pm tomorrow"*

Pass: each transcribes to natural English with no glossary-induced artifacts
(no `Qwen` appearing in random places, no over-frequent identifier mentions).

## Target-term phrases (cleanup-LLM should correct these)

Dictate 2 each. Record pass/fail per attempt.

| Target term | Phrase to dictate | Pass / fail |
|---|---|---|
| FSEventStream | *"the FSEventStream callback runs on the watcher's private dispatch queue"* | ☐☐ |
| Qwen | *"Qwen handled the cleanup well that round"* | ☐☐ |
| AVAudioEngine | *"AVAudioEngine attached the input node before installing the tap"* | ☐☐ |

Pass criterion: target term ≥ 5/6 attempts. The measurement is on the final
pasted output, which has run through cleanup — the raw whisper transcript may
still say "FS event stream"; that's expected.

## Bounds smoke

For each, verify (a) banner posts, (b) `presets.json` defaults + overrides
still load (dictate into a known-overridden app like Slack and confirm the
expected per-app preset is applied), (c) repeat-save of same bad file does
**not** repost the banner (dedupe on `PresetStore.lastSurfacedVocabWarning`).

| Bad vocab | Expected banner | Pass |
|---|---|---|
| 51 entries (any) | "Too many vocabulary entries… (max 50) — vocabulary disabled." | ☐ |
| One entry > 64 chars | "A vocabulary entry… is too long (max 64 chars) — vocabulary disabled." | ☐ |
| ~700 B raw total | "Vocabulary… is too large overall (max 512 B) — vocabulary disabled." | ☐ |
| `"vocabulary": "FSEventStream"` (string, not array) | "Vocabulary… is malformed (expected an array of strings) — vocabulary disabled." | ☐ |

## Init-time + MenuBarController paths

- **Init-time:** Quit the app. Edit `presets.json` to contain a 51-entry vocab.
  Relaunch. The "Too many vocabulary entries…" banner should post at launch.
  Open `presets.json` again (don't change anything) and `touch` it to trigger
  a reload — banner should **not** repost (dedupe).
- **MenuBarController:** With a bad vocab still on disk, click the menu's
  "Reload Presets" item → banner posts via the shared helper.
