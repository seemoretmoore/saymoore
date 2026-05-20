# Slice 7 — History Log: Manual Test Matrix

Branch: `feat/slice-7-history-log`  HEAD: `<fill in after merge>`

## Pre-flight
- Build Debug, install via `scripts/install-debug.sh`, launch `~/Applications/SayMoore.app`.
- Confirm app support dir is clean OR back up `~/Library/Application Support/SayMoore/History.noindex/history.jsonl` if it exists.

## T1 — First dictation creates dir + file
- Dictate one phrase, confirm paste lands.
- Verify `~/Library/Application Support/SayMoore/History.noindex/` exists.
- `stat -f '%Sp %N' ~/Library/Application\ Support/SayMoore/History.noindex` should show `drwx------`.
- `stat -f '%Sp %N' ~/Library/Application\ Support/SayMoore/History.noindex/history.jsonl` should show `-rw-------`.
- File has exactly 1 line of valid JSON; schema fields present (`jq -c . history.jsonl` parses without error).
- Required fields per entry: `schemaVersion`, `id`, `timestamp`, `durationSeconds`, `rawTranscript`, `cleanedTranscript`, `bundleID`, `wordCount`.

## T2 — Rolling cap at 50
- Dictate 60 short phrases (counting on screen helps).
- `wc -l ~/Library/Application\ Support/SayMoore/History.noindex/history.jsonl` should print `50`.
- The first surviving entry's `rawTranscript` should be from the 11th dictation, not the 1st.

## T3 — Menu item reveals the file
- Click menu bar icon → "Open Debug Log in Finder".
- Finder opens with `history.jsonl` selected.

## T4 — Spotlight exclusion
- `mdfind -name history.jsonl` should NOT list the file (because of `.noindex` suffix on the parent dir).
- `xattr -l ~/Library/Application\ Support/SayMoore/History.noindex` should include `com.apple.metadata:com_apple_backup_excludeItem` OR the URL-resource backup-exclusion key should be observable. Spot-check via `mdls` if needed.

## T5 — Rapid back-to-back dictations don't corrupt
- Dictate 5 phrases as fast as possible (Ctrl-Ctrl, speak, Ctrl-Ctrl).
- `wc -l history.jsonl` increments by 5 with no malformed lines.
- `jq -c . history.jsonl` parses every line without error.

## T6 — Cleanup-failed path still appends
- Quit Ollama (menu-bar icon → Quit). Dictate once. Confirm raw transcript is pasted (fallback).
- Confirm `history.jsonl` last line has populated `rawTranscript`. `cleanedTranscript` may be `null` (no cleanup distinct from raw) or populated depending on which fallback fired.

## T7 — Reveal-dir fallback when file doesn't exist
- `rm history.jsonl`. Open menu → "Open Debug Log in Finder". Finder should reveal the `History.noindex` directory (file missing → parent fallback).

## T8 — Paste-failure does NOT append
- Activate an app that blocks paste (rare, but exercise if reproducible — e.g., a focused secure-input field that rejects Cmd-V).
- Dictate. Confirm the failure banner fires AND `history.jsonl` line count did NOT increase.
- Rationale: history is scoped to the paste-success path so the file matches what the user actually pasted.

## Sign-off
- [ ] All T1–T8 pass on commit `<sha>`.
