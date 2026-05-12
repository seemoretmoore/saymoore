# Slice 2 — ModelDownloader bootstrap (manual)

Closes the remaining Slice 2 thread: SHA256 verification + first-run UI.

## Setup

```sh
rm -rf "$HOME/Library/Application Support/SayMoore/models"
bash scripts/generate-project.sh
xcodebuild -project SayMoore.xcodeproj -scheme SayMoore -configuration Debug build
open build/Debug/SayMoore.app    # or Run from Xcode
```

## Cases

### 1. Cold first launch
- Delete model dir (above).
- Launch app.
- **Expect**: setup window appears, progress bar advances, SHA256 verifies, window closes, menu bar icon armed. Total time on a fast link: ~10-20 min for 1.6 GB.
- **Verify**: file at `~/Library/Application Support/SayMoore/models/ggml-large-v3-turbo.bin` exists, sentinel `.download-in-progress` removed. `shasum -a 256` matches the constant in `WhisperModel.swift`.

### 2. Warm subsequent launch
- Quit and relaunch.
- **Expect**: setup window does NOT appear; menu bar icon armed immediately.

### 3. Resume after interruption
- Cold-launch, let progress reach ~10%, force quit (Cmd-Q if window has focus, else Activity Monitor).
- **Verify**: partial file present, sentinel present.
- Relaunch.
- **Expect**: progress resumes from current byte count, completes.

### 4. SHA256 mismatch
- After download completes, corrupt: `printf x >> ~/Library/Application\ Support/SayMoore/models/ggml-large-v3-turbo.bin && touch ~/Library/Application\ Support/SayMoore/models/ggml-large-v3-turbo.bin.download-in-progress`
- Relaunch.
- **Expect**: download re-runs, fails verification, UI shows "Downloaded file did not match expected SHA256." with Retry / Quit. Retry restarts the download.

### 5. Offline
- Disable network, delete model, launch.
- **Expect**: UI shows network failure with Retry / Quit. Enable network → Retry succeeds.

## Notes

- The setup window is `.floating` and `.titled` (closable from system menu only via Quit button to ensure pipeline doesn't arm without a model).
- Hotkey is NOT installed until bootstrap reports `.ready` — pressing Ctrl-Ctrl during setup is a no-op by design.
