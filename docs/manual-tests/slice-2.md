# Slice 2 — Manual Test Plan

End-to-end pipeline: hotkey → record → transcribe → paste, with all PRD integrity checks.

## Status of this slice

- ✅ Pure-logic services (`Transcript`, `ModelDownloader`, `PasteService`) shipped with TDD coverage.
- ✅ `PipelineCoordinator` wired through full state machine, tested with fakes.
- ✅ `Vendor/whisper.xcframework` (v1.7.6) built and linked. Real `WhisperTranscriptionService` active under `#if canImport(whisper)`.
- ⚠️ Model download UI not yet shipped. To exercise live transcription today, drop `ggml-large-v3-turbo.bin` manually into `~/Library/Application Support/SayMoore/models/` (≈1.6 GB — fetch from `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin`). The download flow in `ModelDownloader` is fully tested and ready to wire to a SwiftUI sheet next.

## Acceptance checks

These cover the PRD acceptance items for Slice 2. Drop the model file at the path above first, then run the app.

| # | Action | Expected |
|---|--------|----------|
| 1 | Cold launch with no model present. | Model download sheet appears, completes, sentinel removed only after SHA256 passes. |
| 2 | Re-launch. | Model loaded into memory at app-start; no download dialog. |
| 3 | Dictate "hello world" in TextEdit. | Text appears in the focused field within ~3 s. |
| 4 | **Focus-change test** (PRD): start dictation in TextEdit, Cmd-Tab to a different app while transcription runs. | Notification "Focus changed — paste manually". Transcript on the clipboard. **No paste fires into the wrong app.** |
| 5 | **Clipboard-contention test** (PRD): during the 200 ms restore window, run `osascript -e 'set the clipboard to "interloper"'` from another terminal. | SayMoore detects contention, doesn't clobber, logs warning, fires notification "Clipboard contended — your text is on the clipboard." |
| 6 | Captured bundle ID flow | Log shows the bundleID captured at first Ctrl-down on every dictation; same value passed to `PasteService.paste(...)`. |
| 7 | Garbage detection | Hit hotkey, stay silent ~3s, hit again. Transcript flagged `isGarbage` (`avgNoSpeechProb > 0.9`). State briefly enters `.error(.transcriptionGarbage)`, then `.idle`. No paste. |

## Storage hygiene

```
ls -la ~/Library/Application\ Support/SayMoore/models/
stat -f '%Sp %N' ~/Library/Application\ Support/SayMoore/models/*
```

- `ggml-large-v3-turbo.bin` mode `-rw-------` after a successful download.
- `ggml-large-v3-turbo.bin.download-in-progress` sentinel **only** present mid-download or after a SHA256 mismatch.

## Open work tracked elsewhere

- `ModelDownloader` does not yet have a UI sheet — needed to satisfy "model download sheet appears" in acceptance #1. Backend logic is fully tested; SwiftUI hookup + SHA256 hardcoding are the missing pieces.
