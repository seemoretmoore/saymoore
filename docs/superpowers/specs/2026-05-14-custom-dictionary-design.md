# Custom Dictionary — design

> **Superseded-mechanism note (2026-05-15):** Implementation pivoted to cleanup-LLM glossary injection after manual smoke (0/6 target terms) proved whisper `initial_prompt` cannot fuse phonetically-separated identifiers (e.g., spoken "F-S event stream" reaches whisper as five distinct phonetic chunks; token biasing only nudges close-call alternatives, not acoustic boundaries). The Wiring and Bounds sections below describe the **approved-but-disproven** original design; kept verbatim as the audit trail. Vocabulary now flows into the per-app cleanup prompt as a "Known technical terms" glossary line above the `<transcript>` fence. Bounds (50 entries / 64 B / 512 B) remain in force — now justified by LLM-prompt hygiene rather than whisper's ~224-token initial_prompt budget. User-facing config (`vocabulary` array in `presets.json`), banner pattern, and dedupe semantics are unchanged.

**Status:** approved 2026-05-14, queued behind Bundle B+C merge.
**Owner:** Tracy.
**Targets:** v1.1 enhancement (no PRD slice collision).

## Context

SayMoore Slice 3 tuning surfaced acoustic misses on project-specific identifiers: `FSEventStream` → "FS event stream", `Qwen` → "Clem", `AVAudioEngine` → "av audio engine". `docs/PRD.md` deferred this as "post-v1 enhancement; needs measurement to justify the prompt budget" (see `project_saymoore.md` deferred-items list).

This spec turns that deferral into a concrete feature: a user-curated vocabulary list, injected into Whisper's `initial_prompt`, fixing those misses without disturbing common-English transcription.

The feature was selected during a 2026-05-14 brainstorming pass benchmarked against Glaido's "custom dictionaries" capability, with a deliberate choice to keep SayMoore's local-only, file-edited UX.

## Schema

`presets.json` gains an optional top-level `vocabulary: [String]` array. Missing or empty preserves current behavior (no biasing).

```json
{
  "default": { "promptTemplate": "…" },
  "overrides": { … },
  "vocabulary": ["FSEventStream", "AVAudioEngine", "Qwen", "Ollama", "SayMoore"]
}
```

## Wiring

- `SayMoore/Services/PresetStore.swift` parses the new key and exposes `current.vocabulary: [String]` alongside existing accessors.
- `SayMoore/Services/TranscriptionService.swift` formats the list with a **sentence wrapper** — `"The following transcript may include these terms: <comma-joined-list>."` — and passes it to whisper.cpp as `initial_prompt`. Empty list → pass `NULL` to whisper.cpp, no overhead, no biasing.
- Sentence-form is chosen over bare-list because Whisper's LM head receives more contextual signal from a natural-language frame; the trade-off is ~8 tokens of wrapper overhead against Whisper's 224-token context budget.

## Bounds (defense-in-depth, mirrors A2)

- ≤ 50 entries.
- ≤ 64 chars per entry.
- Total wrapped string ≤ 1 KB.
- Each entry is trimmed of leading/trailing whitespace before validation; empty-after-trim entries are dropped without raising an error (tolerant of `[""]` or accidental commas).

Violations surface as three new `PresetStoreError` cases — `.tooManyVocabEntries`, `.vocabEntryTooLong`, `.vocabularyTooLarge` — routed through the existing `AppDelegate.bannerCopy(for:)` switch landed in M6 (Bundle B).

**Failure semantics differ from A2 (whole-file rejection):** vocab is non-essential. On a vocab-bounds violation the rest of `presets.json` (default prompt + per-app overrides) still loads normally; only the `vocabulary` field is discarded for that load, with a banner posted so the user knows their edit was rejected. Transcription proceeds without biasing rather than falling back to last-good config. This is intentional: a typo in the vocab list should not strand the user without their prompt overrides.

## Hot-reload

The existing `FSEventStream`-based `PresetWatcher` already monitors `presets.json`. Vocab edits propagate to the next dictation. No restart, no new infrastructure.

## Discovery / edit

The existing "Edit Presets…" menu item (A4) reveals `presets.json` in Finder. `SayMoore/Resources/presets.example.json` gains a sample `vocabulary` array with a short doc comment showing usage. No new UI surface.

## Files to modify

| File | Change |
|---|---|
| `SayMoore/Services/PresetStore.swift` | Schema parsing, 3 new error cases, bounds check, accessor `current.vocabulary`. |
| `SayMoore/Services/TranscriptionService.swift` | `vocabularyPromptString(_:)` helper, `initial_prompt` plumbing to whisper.cpp. |
| `SayMoore/Resources/presets.example.json` | Sample `vocabulary` entries with a comment. |
| `SayMoore/Core/Errors.swift` | 3 new `PresetStoreError` cases + discriminant arms (extending the pattern from A6). |
| `SayMoore/App/AppDelegate.swift` | Extend `bannerCopy(for:)` for the 3 new discriminants. |
| `SayMooreTests/PresetStoreTests.swift` | Parse, bounds rejection (3 cases), hot-reload assertion. |
| `SayMooreTests/TranscriptionVocabBiasTests.swift` *(new)* | Formatter assertions: empty list → nil, sentence wrapping, comma joining. |
| `SayMooreTests/PresetStoreBannerCopyTests.swift` | Banner-copy tests for the 3 new discriminants. |
| `docs/manual-tests/vocab-biasing.md` *(new)* | Before/after manual-test log. |

## Reused components

- `PresetStore` bounds-validation pattern (A2).
- `PresetStoreError` discriminant + banner-copy switch (A6 + M6).
- `PresetWatcher` hot-reload (Slice 4).
- "Edit Presets…" menu item (A4) for discovery.
- whisper.cpp `whisper_full_params.initial_prompt` field.

No new infrastructure.

## Verification

1. `xcodebuild -project SayMoore.xcodeproj -scheme SayMoore -destination 'platform=macOS' test` — all existing tests green plus new ones.
2. Manual: edit `~/Library/Application Support/SayMoore/presets.json`, add `"vocabulary": ["FSEventStream", "Qwen", "AVAudioEngine"]`, dictate the F1/F2/F3 regression phrases plus 5 new phrases each containing one of the target terms. Record results in `docs/manual-tests/vocab-biasing.md`. Pass criterion: target term transcribes correctly ≥ 8/10 attempts with no regression on common-English phrases (compare against Slice 3 baseline).
3. Bounds smoke: write a `vocabulary` with 51 entries → vocab discarded, banner posted, transcription proceeds with no biasing. Same for a 65-char entry and for a 1.5 KB total list.

## Out of scope (deferred to follow-on specs)

- Per-app vocabulary (additive override) — defer until global proves insufficient. Re-uses the existing per-app preset merge pattern when added.
- Pronunciation hints / IPA — whisper.cpp doesn't accept these.
- Auto-extracted vocab from clipboard or recent typing.
- Vocabulary editor UI — bundled with the broader v1.1 settings pane.

## Slice impact

None. Doesn't touch Slice 5 (VAD), Slice 6 (HUD/pulse/cursor), or any locked PRD decision. Banner-copy hook reuses M6, currently mid-flight on `bundle-b-narrow`. This spec lands as a v1.1 enhancement after the B+C merge completes.
