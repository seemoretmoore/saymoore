# SayMoore

Local, free, durable voice dictation for macOS.

Hit a hotkey, talk, get clean text pasted into the focused field. Everything runs on-device — Whisper transcription in-process, Qwen 2.5 7B cleanup via local Ollama. No API costs, no subscriptions, no network at runtime.

> **Status:** in active development. See [`docs/PRD.md`](docs/PRD.md) for the full product spec and slice plan. Not yet ready for general use.

## How it works

1. Press **Ctrl-Ctrl** (double-tap Control)
2. Speak
3. Press **Ctrl-Ctrl** again — or stay silent for 10s, or hit the 90s cap
4. SayMoore transcribes locally with `whisper-large-v3-turbo`, applies a per-app tone preset via Ollama (`qwen2.5:7b-instruct`), and pastes the cleaned text into your focused field

Press **Esc** during recording to discard.

## Status / what's shipped

This repo is being built one vertical slice at a time. Track progress in the [GitHub Project board](https://github.com/seemoretmoore/saymoore/projects).

| Slice | Description | Status |
|---|---|---|
| 0 | Scaffold + signing + cross-cutting infrastructure | ⬜ |
| 1 | Hotkey + audio capture | ⬜ |
| 1.5 | Whisper SwiftPM spike | ⬜ |
| 2 | Pipeline coordinator + transcription + paste-with-integrity | ⬜ |
| 3 | Default cleanup preset via Ollama | ⬜ |
| 4 | Per-app preset overrides | ⬜ |
| 5 | VAD + length cap + warnings | ⬜ |
| 6 | Polish UI: pulse + sounds + cursor indicator + recording HUD | ⬜ |
| 7 | History log | ⬜ |
| 8 | Garbage detection | ⬜ |
| 9 | Recovery handlers + watchdog + notification coalescing | ⬜ |
| 10 | First-run permissions wizard | ⬜ |
| 11 | Sparkle integration + release pipeline | ⬜ |
| 12 | README, screenshots, demo gif, QA pass, v1.0 tag | ⬜ |

## Requirements

- macOS 14 (Sonoma) or later
- M-series Apple Silicon recommended; tested on Apple Silicon
- [Ollama](https://ollama.com) installed locally with `qwen2.5:7b-instruct` pulled
- ~6 GB free RAM while running (1.5 GB Whisper + 4.5 GB Qwen)
- ~6 GB free disk for models

## Install (after first release)

Installation instructions will be added with the v0.1 release. The short version:

```bash
# 1. Install Ollama and pull the cleanup model
brew install ollama
ollama pull qwen2.5:7b-instruct

# 2. Download the SayMoore release zip from GitHub Releases
# 3. Move SayMoore.app to /Applications
# 4. Launch — the first-run wizard handles permissions and Whisper model download
```

## Building from source

```bash
git clone https://github.com/seemoretmoore/saymoore
cd saymoore
bash scripts/setup-signing.sh        # one-time: creates a self-signed cert
xcodebuild -scheme SayMoore -configuration Release
```

The signing script is idempotent — re-running it without `--force-regen` is a safe no-op.

## License

MIT — see [`LICENSE`](LICENSE).
