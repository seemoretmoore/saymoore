# Streaming Partials — Manual Dogfood Log

## T10 — Streaming partials displays during dictation

**Scope:** Settings ▸ General ▸ Streaming partials = Balanced.

**Steps:**
1. Open TextEdit, focus a new doc.
2. Press-and-hold the record hotkey.
3. Dictate a 20 s sentence with rich vocabulary (e.g. "The quick brown fox
   jumps over the lazy dog, then asks AVAudioEngine to please reschedule").
4. Watch the HUD: partial text should appear right of the waveform within
   ~2 s of the first word, update every ~1.5 s, with committed words in
   regular weight and the active tail in italic + dimmer.
5. Release hotkey. Final cleaned transcript pastes into TextEdit. Compare
   against the HUD's last-shown string.

**Pass criteria:**
- Partial text appears within 2 s of first word.
- HUD widens smoothly (no flicker / re-layout jank).
- Final pasted text matches the HUD's last partial ± cleanup adjustments
  (punctuation, capitalization).
- Glass pill blur + bars + 4 px anchor visually unchanged.

**Result (run YYYY-MM-DD):** PASS / FAIL — notes.

## CPU calibration — Balanced mode (REQUIRED before ship)

**Setup:** Activity Monitor open. macOS 14.x+, M2 Ultra Mac Studio.
- **Tab:** *CPU* (not Energy, Memory, Disk, or Network).
- **Filter:** type "SayMoore" in the search field (top right) so only the
  app's row is visible.
- **Column to watch:** **% CPU**. On Apple Silicon a single full core ≈ 100 %,
  so the 30 % threshold means "≤ 30 in the % CPU column" — *not* 30 % of
  total system CPU. (Activity Monitor reports per-process % normalized to
  one core, not to the entire chip.)

**Procedure:**
1. Settings ▸ Streaming partials = Balanced.
2. Three back-to-back 60 s dictations in TextEdit. Read aloud from a book.
3. Note **peak** (highest momentary value while talking) and **sustained**
   (the value the row settles at while dictation is actively running, *not*
   the brief spike during the final cleanup pass after you release the hotkey).

**Acceptance:** sustained % CPU during recording ≤ 30 (≈ one-third of a single
core on Apple Silicon).

**Run YYYY-MM-DD:**
- Trial 1: peak __ %, sustained __ %.
- Trial 2: peak __ %, sustained __ %.
- Trial 3: peak __ %, sustained __ %.

**Decision:** if any trial sustained > 30 % one core, bump
`StreamingMode.balanced.intervalSeconds` from 1.5 to 2.0, regenerate
project, re-test, and update the spec at
`docs/superpowers/specs/2026-05-24-streaming-partials-design.md` § Transcription engine.

## T10b — Off-mode regression

**Scope:** Streaming partials = Off.

**Steps:** repeat existing T1 dictation in TextEdit.

**Pass criteria:** behavior identical to current main; HUD shows waveform-
only as today; pill width never changes from 130.

**Result (run YYYY-MM-DD):** PASS / FAIL.

## T10c — Responsive-mode CPU check (informational)

**Scope:** Streaming partials = Responsive.

**Procedure:** one 60 s dictation; record peak + sustained CPU.

**Result (run YYYY-MM-DD):**
- peak __ %, sustained __ %.

**Acceptance:** sustained ≤ 60 % one core. Documented for user awareness
on the Responsive label.
