# Slice 1.5 — Whisper SwiftPM spike

**Date:** 2026-05-09
**Status:** ❌ on the original plan (SwiftPM); ⚠️ available via XCFramework. Decision required from the author before Slice 2 begins.

---

## Goal

Per PRD: prove that `whisper.cpp` can be linked in-process via SwiftPM and used for transcription before committing to that path in Slice 2.

## What I tried

1. Added a `whisper` package entry to `project.yml`:
   ```yaml
   packages:
     whisper:
       url: https://github.com/ggerganov/whisper.cpp
       branch: master
   ```
2. Created a throwaway `WhisperSpike` `tool` target that imports `whisper`, loads `ggml-large-v3-turbo.bin`, parses a 16 kHz mono WAV, and calls `whisper_full`.
3. Ran `xcodebuild -scheme WhisperSpike build`.

## What happened

```
xcodebuild: error: Could not resolve package dependencies:
  the package manifest at '/Package.swift' cannot be accessed
  (/Package.swift doesn't exist in file system)
  in https://github.com/ggerganov/whisper.cpp
```

Probed both repos:

- `ggerganov/whisper.cpp` (the URL on the PRD) — repo redirects, no `Package.swift`.
- `ggml-org/whisper.cpp` (canonical home as of 2026) — `git ls-tree HEAD` shows no `Package.swift`. Same for `v1.7.4`, `v1.7.6`, `v1.8.4`.

The Swift Package manifest has been **removed upstream**. The maintainers now ship in-process integration via an XCFramework produced by `build-xcframework.sh`, with a sample app at `examples/whisper.swiftui/` that imports the C API through a bridging header.

The PRD's locked-decision SwiftPM path is no longer reachable as written.

## Options

### A — XCFramework drop-in (closest to PRD intent)

Run `bash build-xcframework.sh` against a pinned `whisper.cpp` tag, commit the resulting `whisper.xcframework` (or build it as part of `scripts/setup-whisper.sh`), link it from `project.yml`, and call the C API via a bridging header. Still in-process, still warm-loaded across dictations, Metal-backed. Adds ~200 MB of binary artifacts to repo or build pipeline.

- **Pro:** preserves all PRD performance + UX assumptions (warm model, sub-3s latency target). Same C API the PRD prompt assumed; only the packaging changes.
- **Con:** slightly more build-script work than SPM. XCFramework must be regenerated when bumping whisper version. Either commit a 200 MB artifact (no — `models/` is already gitignored) or rebuild via Make in `setup-whisper.sh` (~1 min one-time).
- **Risk:** low. The official sample app uses this exact integration.

### B — Cold-subprocess `whisper-cli` per dictation (PRD ❌ fallback)

`brew install whisper-cpp` (or bundle `whisper-cli` in the .app), spawn it on each dictation, parse stdout. Accept ~1.5s model-load overhead per utterance.

- **Pro:** simplest. Zero linkage, zero bridging headers. Subprocess crashes don't take down SayMoore.
- **Con:** breaks the sub-3s latency target on every dictation (1.5s load + transcribe). Forces deferring warm-helper subprocess to v1.1, which the PRD explicitly does not want.
- **Risk:** medium — every short utterance ("yes", "ok") pays the load cost; the fast-path skip-cleanup decision in the PRD assumes the transcript is already cheap.

### C — Vendor a Package.swift fork

Fork `whisper.cpp` to a SayMoore-controlled repo, restore a `Package.swift` (the previous one, last seen in late-2024 history is recoverable), pin to a specific commit. SPM-clean.

- **Pro:** matches PRD literally. SPM integration as written.
- **Con:** ongoing maintenance — must rebase against upstream whenever ggml restructures (which is the reason they removed Package.swift). Adds a fork to the org footprint that has nothing to do with SayMoore beyond packaging.
- **Risk:** medium-low at first, growing over time as upstream and fork diverge.

## Recommendation

**Option A (XCFramework)**. It preserves every PRD performance assumption — warm model, in-process, Metal — and only changes the packaging mechanism. Build cost is a one-time `bash scripts/setup-whisper.sh` step that fits naturally next to `setup-signing.sh`.

If A is rejected, **Option B** (subprocess) is the documented PRD ❌ fallback and is honest about its trade-offs; Option C buys SPM purity at a maintenance tax that gets worse over time.

## Decision

> **Author:** picked option ____ on ____.

Spike target reverted from `project.yml`; main app still builds clean. No artifacts retained beyond this writeup.
