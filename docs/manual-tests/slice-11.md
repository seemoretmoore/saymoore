# Slice 11 — Sparkle + Release Pipeline Manual Tests

## Preconditions
- `scripts/setup-signing.sh` has been run (Self-Sign cert in login Keychain).
- `scripts/setup-sparkle-key.sh` has been run; `SUPublicEDKey` in Info.plist matches.
- `gh` is authenticated against `github.com/seemoretmoore/saymoore`.

## T1 — Menu item exists and opens Sparkle
1. Build Debug. Launch. Click menu-bar icon.
2. Expect: "Check for Updates…" item present, between "Open Debug Log in Finder" and "Quit".
3. Click it. Expect: Sparkle's progress sheet appears within 2s; no crash.

## T2 — Background check fires (optional)
1. Set system clock forward 25h, relaunch.
2. Expect: a background check occurs (verify via Console.app filter `Sparkle`).

## T3 — `build-release.sh` is hermetic
1. From a clean checkout: `bash scripts/build-release.sh`.
2. Expect: `release/<version>/SayMoore-<version>.zip` + `.sig` + `.length` exist.
3. Verify:
   ```
   build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update \
       --account SayMoore --verify \
       release/<version>/SayMoore-<version>.zip \
       "$(cat release/<version>/SayMoore-<version>.sig)"
   ```
   Expect: no error output (exit 0).

## T4 — v0.9 → v1.0 update round-trip
1. With `MARKETING_VERSION 0.9.0` in `project.yml`: `bash scripts/publish-release.sh`.
2. Install: `rm -rf /Applications/SayMoore.app && ditto -xk release/0.9.0/SayMoore-0.9.0.zip /Applications/ && open /Applications/SayMoore.app`.
3. Menu → "Check for Updates…". Expect: "You're up to date!".
4. Quit. Bump `MARKETING_VERSION` to `1.0.0`, `CURRENT_PROJECT_VERSION` to `2`. Regenerate project. `bash scripts/publish-release.sh`.
5. `open /Applications/SayMoore.app` (still 0.9.0). Menu → "Check for Updates…".
6. Expect: Sparkle finds 1.0.0, downloads, verifies, installs, relaunches.
7. After relaunch: `plutil -extract CFBundleShortVersionString raw /Applications/SayMoore.app/Contents/Info.plist` → `1.0.0`.

## T5 — Tampered zip rejected
1. After T4, corrupt the v1.0.0 zip on GitHub:
   ```
   printf 'extra' >> release/1.0.0/SayMoore-1.0.0.zip
   gh release upload v1.0.0 release/1.0.0/SayMoore-1.0.0.zip --clobber --repo seemoretmoore/saymoore
   ```
2. Reinstall v0.9.0 (step 2 of T4). Menu → "Check for Updates…".
3. Expect: Sparkle aborts with a signature-mismatch error. App is NOT replaced.
4. Restore the correct zip: `gh release upload v1.0.0 <original-zip> --clobber --repo seemoretmoore/saymoore`.

## T6 — Idempotent key setup
1. With the Keychain entry present, run `scripts/setup-sparkle-key.sh`.
2. Expect: prints existing public key and exits 0.
3. With `--force-regen`: prints a rotation warning, replaces the entry, prints new public key.

## T7 — TCC permissions survive the update
1. Before T4, grant Accessibility + Input-Monitoring + Mic to v0.9.0.
2. After update to v1.0.0, dictate once (Ctrl-Ctrl, speak, Ctrl-Ctrl).
3. Expect: no permission re-prompt; dictation completes and pastes.

## Results
- [ ] T1
- [ ] T2 (optional)
- [ ] T3
- [ ] T4
- [ ] T5
- [ ] T6
- [ ] T7
