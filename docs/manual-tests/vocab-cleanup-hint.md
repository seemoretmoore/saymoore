# Custom vocabulary (deterministic substitution) — manual test

Verifies that the v1.1 Custom Dictionary feature corrects acoustic misses on
project-specific identifiers without regressing common-English transcription.

> **Mechanism note (2026-05-15, iteration 3):** Vocabulary entries are
> `{phonetic, canonical}` pairs. A deterministic case-insensitive
> word-boundary regex substitution runs on the cleanup output (and on the
> fallback path when cleanup is skipped/unavailable). LLM-based variants
> (`initial_prompt` and cleanup-LLM glossary) both failed manual smoke;
> see the spec's Superseded-mechanism note for the audit trail. Pass rates
> should now be deterministic — given a phonetic mapping that matches what
> whisper actually produces, substitution is 100%.

## Setup

1. `bash scripts/install-debug.sh && open ~/Applications/SayMoore.app`.
2. Edit `~/Library/Application Support/SayMoore/presets.json`. Add a top-level key:

   ```json
   "vocabulary": [
     {"phonetic": "FS event stream", "canonical": "FSEventStream"},
     {"phonetic": "AV audio engine", "canonical": "AVAudioEngine"},
     {"phonetic": "Quinn", "canonical": "Qwen"},
     {"phonetic": "Clem", "canonical": "Qwen"}
   ]
   ```

3. Save. `PresetWatcher` hot-reloads within ~100 ms.

## Regression phrases (must still transcribe correctly)

Dictate each:

- F1 — *"hi alex, i think we should ship friday and also fix the api timeout"*
- F2 — *"add a unit test for the cleanup service"*
- F3 — *"the meeting is at three pm tomorrow"*

Pass: each transcribes to natural English. No spurious substitutions
(no `Qwen` appearing in random places, no `FSEventStream` mid-sentence).

## Target-term phrases (substitution must fix these)

Dictate each twice. The **final pasted output** is what counts.

| Target phonetic → canonical | Phrase to dictate | Pass / fail |
|---|---|---|
| FS event stream → FSEventStream | *"the FSEventStream callback runs on the watcher's private dispatch queue"* | ☐☐ |
| Quinn or Clem → Qwen | *"Qwen handled the cleanup well that round"* | ☐☐ |
| AV audio engine → AVAudioEngine | *"AVAudioEngine attached the input node before installing the tap"* | ☐☐ |

Pass criterion: ≥ 5/6 (substitution should be deterministic — if whisper
produced one of the phonetic mappings you supplied, the rewrite happens 100%
of the time). Misses below 5/6 indicate whisper produced a phonetic form
not in your vocabulary; add another phonetic mapping for that variant.

## Bounds smoke

For each, verify (a) banner posts, (b) `presets.json` defaults + overrides
still load (dictate into a known-overridden app like Slack), (c) repeat-save
of same bad file does **not** repost the banner (dedupe).

| Bad vocab | Expected banner | Pass |
|---|---|---|
| 51 entries | "Too many vocabulary entries… (max 50) — vocabulary disabled." | ☐ |
| One entry with `"phonetic"` > 64 bytes | "A vocabulary entry… is too long (max 64 bytes) — vocabulary disabled." | ☐ |
| 5 entries × 60 B each (phonetic + canonical) | "Vocabulary… is too large overall (max 512 B) — vocabulary disabled." | ☐ |
| `"vocabulary": "FSEventStream"` (string, not array) | "Vocabulary… is malformed (expected an array of {phonetic, canonical} entries) — vocabulary disabled." | ☐ |
| `"vocabulary": ["bare string"]` (old v1.1.0 schema) | "Vocabulary… is malformed… — vocabulary disabled." | ☐ |
| Entry missing `"canonical"` key | "Vocabulary… is malformed… — vocabulary disabled." | ☐ |

## Init-time + MenuBarController paths

- **Init-time:** Quit the app. Edit `presets.json` to contain a 51-entry vocab.
  Relaunch. The "Too many vocabulary entries…" banner posts at launch.
  Touch `presets.json` again (no changes) → banner should **not** repost (dedupe).
- **MenuBarController:** With a bad vocab on disk, click "Reload Presets" →
  banner posts via the shared helper.
