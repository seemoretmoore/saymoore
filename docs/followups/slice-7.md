# Slice 7 — Followups

Cosmetic findings from manual testing (2026-05-20). Neither blocks v1 ship.

## F1 — `cleanedTranscript` absent (vs `null`) when nil

**Observed:** JSONL lines omit the `cleanedTranscript` key entirely when the implementation maps it to `nil` (cleanup skipped or returned identical text to raw).

**Why:** Default `JSONEncoder` behavior — optional fields with nil values are not emitted.

**Why it matters:** Any future history-viewer consumer must treat absent `cleanedTranscript` as semantically equivalent to `null` (= "no cleanup distinct from raw"). The JSONL parser in `HistoryStore.loadAllSync` already handles this correctly because the Swift decoder treats missing optional fields as `nil`. Risk is purely for *external* consumers reading the file.

**Fix (when convenient):** set `encoder.keyEncodingStrategy` or use a custom encode method to always emit `null`. Or: document the absent-is-nil contract in the schema header (future v2 history-viewer slice).

## F2 — `wordCount` over-counts contractions

**Observed:** `wordCount: 7` for "Let's play a board game tonight." (6 spoken words).

**Why:** `chosenText.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })` treats `'` as a separator, so "Let's" → ["Let", "s"].

**Why it matters:** Inflates counts for any contraction. Low-stakes — wordCount is a debug field, not a user-visible metric in v1. The "Debug Log" framing covers this.

**Fix (when convenient):** either (a) keep punctuation in word tokens (only split on whitespace), or (b) match `[A-Za-z0-9']+` patterns. Decide whether contractions, hyphens, and possessives should count as one token or split.
