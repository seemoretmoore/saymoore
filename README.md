# SayMoore

Local, free, durable voice dictation for macOS.

Hit a hotkey, talk, get clean text pasted into the focused field. Everything runs on-device — Whisper transcription in-process, Qwen 2.5 7B cleanup via local Ollama. No API costs, no subscriptions, no network at runtime, no audio or transcripts leaving the machine.

> **Status:** in active development. Slices 0–4 are shipped and usable end-to-end; Slices 5–12 still pending (see table below). See [`docs/PRD.md`](docs/PRD.md) for the full product spec.

## How it works

1. Press **Ctrl-Ctrl** (double-tap Control)
2. Speak
3. Press **Ctrl-Ctrl** again — or stay silent for 10s, or hit the 90s cap (VAD + cap land in Slice 5)
4. SayMoore transcribes locally with `whisper-large-v3-turbo`, applies a **per-app tone preset** via Ollama (`qwen2.5:7b-instruct`), and pastes the cleaned text into your focused field

Press **Esc** during recording to discard.

### Per-app presets

The same dictation gets cleaned differently depending on which app is frontmost. Example phrase — *"hi tracy uh i think we should ship friday and also fix the api timeout"*:

| Frontmost app | Cleaned output |
|---|---|
| Slack | `hi tracy, i think we should ship friday and also fix the api timeout` |
| Notes (or anything without an override) | `Hi Tracy, I think we should ship on Friday and also fix the API timeout.` |
| Messages | `hi tracy, i think we should ship on friday and also fix the api timeout` |
| BBEdit (code/notes editor) | `Fix getUserRequest and update JSON schema before calling API endpoint` *(on a different, technical phrase — preserves identifiers, drops articles)* |

Bundled overrides ship for Slack, Notes, Messages, and BBEdit. Edit `~/Library/Application Support/SayMoore/presets.json` to add your own — changes hot-reload without restart. A "Reload Presets" menu item also triggers a manual reload.

### Custom vocabulary (v1.1)

Acoustic misses on project-specific identifiers (`FSEventStream` → "FS event stream", `Qwen` → "Clem") can be fixed by adding a top-level `vocabulary` array to `presets.json`:

```json
{
  "default": "…",
  "overrides": { … },
  "vocabulary": ["FSEventStream", "AVAudioEngine", "Qwen", "Ollama", "SayMoore"]
}
```

The list is injected as a glossary hint into the Ollama cleanup step, correcting those terms in the final output. Edits hot-reload like the rest of `presets.json`.

**Limits** (defense-in-depth, similar to other `presets.json` bounds):

- Up to 50 entries
- Up to 64 chars per entry
- Up to 512 bytes total (raw terms + separators)

On a violation, vocabulary is disabled for that load and a notification posts; the rest of `presets.json` (default + per-app overrides) keeps working. Repeat saves of the same bad file stay quiet (dedupe). See [`docs/manual-tests/vocab-cleanup-hint.md`](docs/manual-tests/vocab-cleanup-hint.md) for the test protocol.

## Status / what's shipped

This repo is being built one vertical slice at a time. Track progress in the [GitHub Project board](https://github.com/seemoretmoore/saymoore/projects).

| Slice | Description | Status |
|---|---|---|
| 0 | Scaffold + signing + cross-cutting infrastructure | ✅ |
| 1 | Hotkey + audio capture | ✅ |
| 1.5 | Whisper SwiftPM spike | ✅ |
| 2 | Pipeline coordinator + transcription + paste-with-integrity | ✅ |
| 3 | Default cleanup preset via Ollama | ✅ |
| 4 | Per-app preset overrides | ✅ |
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
- M-series Apple Silicon recommended; tested on M2 Ultra
- [Ollama](https://ollama.com) installed locally with `qwen2.5:7b-instruct` pulled
- ~6 GB free RAM while running (1.5 GB Whisper + 4.5 GB Qwen)
- ~6 GB free disk for models

## Install

No prebuilt binary yet — Slice 11 will ship a signed/notarised release. Until then, build from source (next section). At a high level the flow will eventually be:

```bash
# 1. Install Ollama and pull the cleanup model
brew install ollama
ollama pull qwen2.5:7b-instruct

# 2. Download the SayMoore release zip from GitHub Releases (TBD)
# 3. Move SayMoore.app to /Applications
# 4. Launch — the first-run wizard handles permissions and Whisper model download
```

## Known limitations (today)

- No GUI installer. Build-from-source only.
- No VAD or 90s length cap yet — recording stops on second Ctrl-Ctrl, or at the 2-min hard ring-buffer limit.
- No visible recording HUD; cursor doesn't change. Menu-bar icon and a soft chime are the only feedback.
- Self-signed: macOS Gatekeeper will warn on first launch. TCC grants for Microphone / Accessibility / Input Monitoring must be granted manually in System Settings.
- Apple Silicon (M-series) only in practice — the Whisper model runs on the Neural Engine.

## Building from source

```bash
git clone https://github.com/seemoretmoore/saymoore
cd saymoore

brew install xcodegen cmake           # one-time: project file generator + whisper.cpp build dep
bash scripts/setup-signing.sh         # one-time: creates a self-signed cert in your login keychain
bash scripts/setup-whisper.sh         # one-time: builds Vendor/whisper.xcframework from pinned tag (~5 min)
bash scripts/generate-project.sh      # writes SayMoore.xcodeproj from project.yml
bash scripts/build-release.sh         # or open SayMoore.xcodeproj in Xcode
```

`SayMoore.xcodeproj` is gitignored — regenerate it from `project.yml` whenever you edit sources, targets, or build settings.

The signing script is idempotent — re-running it without `--force-regen` is a safe no-op. Using `--force-regen` rotates the identity, which revokes any Accessibility / Input-Monitoring permissions previously granted to SayMoore.

## License

MIT — see [`LICENSE`](LICENSE).
