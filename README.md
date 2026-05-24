# SayMoore

Local, free, durable voice dictation for macOS.

Hit a hotkey, talk, get clean text pasted into the focused field. Everything runs on-device — Whisper transcription in-process, Qwen 2.5 7B cleanup via local Ollama. No API costs, no subscriptions, no network at runtime, no audio or transcripts leaving the machine.

> **Status:** v1.0 shipped (Sparkle auto-update live). v1.1 in flight on `main` with Command Mode, voice snippets, vocabulary auto-suggest, the Settings window, and a live audio-level HUD. See [`docs/PRD.md`](docs/PRD.md) for the full product spec.

## How it works

1. Press **Ctrl-Ctrl** (double-tap Control)
2. Speak
3. Press **Ctrl-Ctrl** again — or stay silent for 10s (VAD auto-stop), or hit the 90s length cap
4. SayMoore transcribes locally with `whisper-large-v3-turbo`, applies a **per-app tone preset** via Ollama (`qwen2.5:7b-instruct`), and pastes the cleaned text into your focused field

Press **Esc** during recording to discard.

### Per-app presets

The same dictation gets cleaned differently depending on which app is frontmost. Example phrase — *"hi alex uh i think we should ship friday and also fix the api timeout"*:

| Frontmost app | Cleaned output |
|---|---|
| Slack | `hi alex, i think we should ship friday and also fix the api timeout` |
| Notes (or anything without an override) | `Hi Alex, I think we should ship on Friday and also fix the API timeout.` |
| Messages | `hi alex, i think we should ship on friday and also fix the api timeout` |
| BBEdit (code/notes editor) | `Fix getUserRequest and update JSON schema before calling API endpoint` *(on a different, technical phrase — preserves identifiers, drops articles)* |

Bundled overrides ship for Slack, Notes, Messages, and BBEdit. Edit `~/Library/Application Support/SayMoore/presets.json` to add your own — changes hot-reload without restart. A "Reload Presets" menu item also triggers a manual reload.

### Custom vocabulary (v1.1)

Acoustic misses on project-specific identifiers (`FSEventStream` → "FS event stream", `Qwen` → "Clem") can be fixed by adding a top-level `vocabulary` array to `presets.json`. Each entry is a `{phonetic, canonical}` pair — the phonetic form is what whisper transcribes; the canonical form is the rewrite:

```json
{
  "default": "…",
  "overrides": { … },
  "vocabulary": [
    {"phonetic": "FS event stream", "canonical": "FSEventStream"},
    {"phonetic": "AV audio engine", "canonical": "AVAudioEngine"},
    {"phonetic": "Quinn",           "canonical": "Qwen"},
    {"phonetic": "Clem",            "canonical": "Qwen"}
  ]
}
```

A deterministic case-insensitive word-boundary substitution runs after the Ollama cleanup step (and on the fallback path when cleanup is skipped/unavailable), so each `phonetic` form in the final output gets rewritten to the corresponding `canonical`. Multiple phonetics can map to the same canonical. Edits hot-reload like the rest of `presets.json`.

**Limits** (defense-in-depth, similar to other `presets.json` bounds):

- Up to 50 entries
- Up to 64 bytes per `phonetic` or `canonical`
- Up to 512 bytes total (sum of all phonetic + canonical bytes)

On a violation, vocabulary is disabled for that load and a notification posts; the rest of `presets.json` (default + per-app overrides) keeps working. Repeat saves of the same bad file stay quiet (dedupe). See [`docs/manual-tests/vocab-cleanup-hint.md`](docs/manual-tests/vocab-cleanup-hint.md) for the test protocol.

### Command Mode (v1.1)

For up to 5 seconds after a dictation lands, press **Ctrl-Ctrl** again and speak an edit instead of new text. Examples: *"make it more formal"*, *"add a polite ending"*, *"make it shorter"*. SayMoore sends Cmd-Z to undo the prior paste, then pastes the rewritten version. Chains cleanly — each successful rewrite resets the 5s window, so you can iterate. Works in AppKit-based text fields (Notes, TextEdit, Messages, Mail, Slack, BBEdit). Apps that don't treat paste as a single undo unit (Terminal, some Catalyst apps) will append instead of replace — known limitation.

If focus moves to a different app before the rewrite completes, the rewrite is discarded with a "focus changed" banner — no Cmd-Z ever fires in the wrong app.

### Voice snippets (v1.1)

Define text snippets in `presets.json` and expand them by voice. Each entry is a `{name, body}` pair under the top-level `snippets` map. Dictate *"insert signature"* and SayMoore expands the matching snippet inline before the cleanup step runs. Useful for sign-offs, addresses, code stubs, or any block of text you say verbatim more than once a week.

### Live audio level (v1.1)

The recording HUD shows a 12-bar animated waveform driven by mic RMS. Bars pulse with your voice and stay flat on silence, so you can tell at a glance whether your input is being picked up. The pill anchors to the bottom of the active window and follows you across Cmd-Tab.

### Settings window (v1.1)

`Cmd-,` opens a four-tab Settings window: **General** (launch at login, sounds, hotkey reminder), **Presets** (status + reload), **Vocabulary** (review the loaded auto-suggested terms), **About** (version + update check). All editable state still lives in `presets.json`; Settings is a read-mostly inspector with a few toggles.

### Vocabulary auto-suggest (v1.1)

When the same proper-noun-like term gets transcribed inconsistently across recordings (e.g., `Anthropic` vs `anthropy`), SayMoore offers to add it to the vocabulary list. Accept once and future transcriptions stay correct. Whisper's `initial_prompt` is biased with the current vocabulary's canonical forms so the model is primed to hear them.

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
| 5 | VAD + length cap + warnings | ✅ |
| 6 | Polish UI: pulse + sounds + cursor indicator + recording HUD | ✅ |
| 7 | History log | ✅ |
| 8 | Garbage detection | ✅ |
| 9 | Recovery handlers + watchdog + notification coalescing | ✅ |
| 10 | First-run permissions wizard | ✅ |
| 11 | Sparkle integration + release pipeline | ✅ |
| 12 | README, screenshots, demo gif, QA pass, v1.0 tag | ✅ |

## Requirements

- macOS 14 (Sonoma) or later
- M-series Apple Silicon recommended
- [Ollama](https://ollama.com) installed locally with `qwen2.5:7b-instruct` pulled
- ~6 GB free RAM while running (1.5 GB Whisper + 4.5 GB Qwen)
- ~6 GB free disk for models

## Install

```bash
# 1. Install Ollama and pull the cleanup model
brew install ollama
ollama pull qwen2.5:7b-instruct
```

2. Download `SayMoore-<version>.zip` from the [latest release](https://github.com/seemoretmoore/saymoore/releases/latest).
3. Unzip and drag `SayMoore.app` into `/Applications`.
4. Launch. macOS will warn that the app is from an unidentified developer — right-click → **Open** → **Open** to confirm (one-time). The first-run wizard walks through Microphone, Accessibility, Input Monitoring, and Notification permissions, then downloads the Whisper model (~1.5 GB).
5. Press **Ctrl-Ctrl** in any text field and start talking.

You should be dictating within ~5 minutes of clicking Download.

### Hotkey

**Ctrl-Ctrl** (double-tap Control within ~250ms) starts and stops recording. **Esc** discards an in-progress recording. The hotkey is global — works in any focused text field.

### Updates

SayMoore checks for updates daily via [Sparkle](https://sparkle-project.org). Click the menu-bar icon → **Check for Updates…** to check now. Updates are EdDSA-signed; tampered downloads are rejected automatically.

## Troubleshooting

- **"App is damaged and can't be opened" / Gatekeeper blocks launch.** SayMoore is self-signed, not notarized. Right-click → **Open** → **Open** the first time. If that still fails, run `xattr -dr com.apple.quarantine /Applications/SayMoore.app` in Terminal once.
- **Ctrl-Ctrl does nothing.** macOS may have silently dropped the Input Monitoring grant after a system update. Open System Settings → Privacy & Security → Input Monitoring, toggle SayMoore off and back on, then relaunch.
- **"No speech detected" banner after every recording.** Mic is muted or Whisper is hearing background noise as silence. Check the Sound preferences input meter while you talk.
- **Cleanup fails with "Ollama unreachable".** Run `ollama serve` (or launch the Ollama menu-bar app). Verify with `curl http://127.0.0.1:11434/api/tags`.
- **First Ctrl-Ctrl of the day records 0 samples.** Known AVAudioEngine warmup quirk — try again immediately, the second attempt always works.
- **Per-app cleanup gives the wrong tone.** Edit `~/Library/Application Support/SayMoore/presets.json` and reload via the menu-bar item, or just save the file — it hot-reloads.

## Known limitations

- Self-signed, not notarized. macOS Gatekeeper warns on first launch (see Troubleshooting).
- Apple Silicon (M-series) only in practice — Whisper runs on the Neural Engine.
- Recording cap is 90 seconds (warning at 80s). For longer dictations, stop and restart.

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

## Contributing workflow

`main` is protected. Changes land via pull request:

```bash
git switch -c fix/short-description
# edit, build, commit
git push -u origin fix/short-description
gh pr create --fill
gh pr merge --auto --squash --delete-branch   # auto-merges when CI is green
```

A local pre-push hook builds the Debug target before allowing push, so a broken branch never reaches GitHub. Install it once:

```bash
bash scripts/install-hooks.sh
```

Set `SKIP_PREPUSH=1` to bypass it for a single push (rarely needed).

CI (GitHub Actions) runs build + tests on every PR; merging is blocked until CI is green. The CI workflow lives in [`.github/workflows/ci.yml`](.github/workflows/ci.yml).

## License

MIT — see [`LICENSE`](LICENSE).
