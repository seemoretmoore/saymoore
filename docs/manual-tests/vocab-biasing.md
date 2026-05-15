# Custom vocabulary biasing — manual test

Verifies that the v1.1 Custom Dictionary feature corrects acoustic misses on
project-specific identifiers without regressing common-English transcription.

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

Pass: each transcribes to natural English with no biasing-induced artifacts
(no `Qwen` appearing in random places, no over-frequent identifier mentions).

## Target-term phrases (biasing should fix these)

Dictate 5 each. Record pass/fail per attempt.

| Target term | Phrase to dictate | Pass / fail |
|---|---|---|
| FSEventStream | *"the FSEventStream callback runs on the watcher's private dispatch queue"* | ☐☐☐☐☐ |
| Qwen | *"Qwen handled the cleanup well that round"* | ☐☐☐☐☐ |
| AVAudioEngine | *"AVAudioEngine attached the input node before installing the tap"* | ☐☐☐☐☐ |

Pass criterion: target term ≥ 8/10 attempts (5 phrases × 2 dictations).

## Token-budget measurement

After a successful daily-launch:

1. Open Console.app, filter `subsystem:com.seemoretmoore.saymoore process:SayMoore`.
2. Run `xcodebuild -project SayMoore.xcodeproj -scheme SayMoore -destination 'platform=macOS' -only-testing:SayMooreTests/WhisperPromptBudgetTests test`.
3. The `testRealisticMaxCapVocabStaysUnderTwoHundredTokens` test prints nothing on success but fails loudly if a future cap loosening pushes tokenization past 200 tokens.
4. Record observed token count from the test output below for future reference:

   - Realistic max-cap (50 CamelCase identifiers): `___` tokens / 224 budget
   - Synthetic worst-case (50 × `Term001`-style): `___` tokens / 224 budget (informational)

## Bounds smoke

For each, verify (a) banner posts, (b) `presets.json` defaults + overrides
still load (dictate into a known-overridden app like Slack and confirm the
expected per-app preset is applied), (c) repeat-save of same bad file does
**not** repost the banner (dedupe on `PresetStore.lastSurfacedVocabWarning`).

| Bad vocab | Expected banner | Pass |
|---|---|---|
| 51 entries (any) | "Too many vocabulary entries… (max 50) — biasing disabled." | ☐ |
| One entry > 64 chars | "A vocabulary entry… is too long (max 64 chars) — biasing disabled." | ☐ |
| ~700 B wrapped total | "Vocabulary… is too large overall (max 512 B) — biasing disabled." | ☐ |
| `"vocabulary": "FSEventStream"` (string, not array) | "Vocabulary… is malformed (expected an array of strings) — biasing disabled." | ☐ |

## Init-time + MenuBarController paths

- **Init-time:** Quit the app. Edit `presets.json` to contain a 51-entry vocab.
  Relaunch. The "Too many vocabulary entries…" banner should post at launch.
  Open `presets.json` again (don't change anything) and `touch` it to trigger
  a reload — banner should **not** repost (dedupe).
- **MenuBarController:** With a bad vocab still on disk, click the menu's
  "Reload Presets" item → banner posts via the shared helper.
