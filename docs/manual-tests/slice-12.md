# Slice 12 — v1.0 acceptance QA

PRD §12 acceptance criteria. Run in one sitting; ~30–45 min.

## 1. 50-dictation stress test

**Goal:** no crashes, RAM stable (±50 MB), file handles stable.

Setup:
1. Launch `~/Applications/SayMoore.app` (Debug build).
2. Open Activity Monitor → search "SayMoore" → note baseline **Memory** and **Open Files & Ports** (View → menu).
3. Open Notes (or any text field).

Run:
- 50 consecutive dictations. Mix it up: short (1-word), medium (1 sentence), long (3+ sentences).
- Every ~10 dictations, switch the frontmost app (Slack → Notes → Messages → BBEdit) to exercise preset overrides.
- No need to wait between attempts beyond Sparkle's natural reset.

Pass:
- [ ] 50/50 completed without crash, hang, or stuck-recording state
- [ ] Final Memory within 50 MB of baseline
- [ ] Final Open Files within 5 of baseline
- [ ] No SayMoore process leaks (`ps aux | grep -i saymoore` shows only the menu-bar app)

Record final numbers:
- Baseline RAM: _____ MB
- Final RAM: _____ MB
- Baseline FDs: _____
- Final FDs: _____

## 2. Four-permission revoke/grant cycle

**Goal:** each permission can be revoked from System Settings and re-granted via the first-run wizard or its dedicated re-grant path.

For each permission below, repeat the cycle:

### 2a. Microphone
1. System Settings → Privacy & Security → Microphone → SayMoore: toggle OFF
2. Attempt dictation. Pass: clear error banner ("Microphone permission denied" or equivalent), no crash.
3. Toggle Microphone ON.
4. Dictation works again.

- [ ] Revoke → banner fires
- [ ] Re-grant → works again

### 2b. Accessibility
1. System Settings → Privacy & Security → Accessibility → SayMoore: toggle OFF
2. Attempt dictation. Pass: paste fails gracefully (clipboard fallback or banner), no crash.
3. Toggle Accessibility ON.
4. Paste works again.

- [ ] Revoke → graceful degradation
- [ ] Re-grant → works again

### 2c. Input Monitoring
1. System Settings → Privacy & Security → Input Monitoring → SayMoore: toggle OFF
2. Ctrl-Ctrl does nothing (expected — hotkey tap dead).
3. Toggle Input Monitoring ON. (May require relaunch — note if so.)
4. Ctrl-Ctrl works again.

- [ ] Revoke → hotkey dies
- [ ] Re-grant → hotkey works (relaunch needed? Y/N: _____)

### 2d. Notifications
1. System Settings → Notifications → SayMoore: toggle Allow Notifications OFF
2. Trigger an error path (e.g. quit Ollama from menu bar, attempt dictation).
3. Pass: app doesn't crash; error logged. Banner may not display (expected).
4. Toggle Notifications ON.
5. Trigger same error path; banner now displays.

- [ ] Revoke → no crash on missing notification
- [ ] Re-grant → banners display

## 3. Sparkle upgrade smoke (dogfood)

Bundled with Step 5 below — when we ship v1.0.1, you'll receive the update via Sparkle and confirm the upgrade path works one more time end-to-end.

## 4. Screenshots / demo gif (optional polish — defer if low-energy)

If you want to attach visuals to the v1.0.1 release notes:
- [ ] Menu-bar idle icon
- [ ] Menu-bar recording icon (with timer pill)
- [ ] Recording HUD on active display
- [ ] First-run wizard
- [ ] Update prompt from Sparkle

Demo gif: 5–10s of "press Ctrl-Ctrl → speak → cleaned text appears." `cmd+shift+5` → record selection → convert to gif. Drop into `docs/assets/demo.gif`, embed in README.

## 5. v1.0.1 release cut

After Tracks A/B/C are green, I run `scripts/publish-release.sh 1.0.1`. You confirm the upgrade prompt appears in the running app and the install completes.

## Sign-off

- [ ] All checks above passed (or explicitly waived)
- [ ] Final RAM/FD numbers recorded
- [ ] Tag `slice-12-shipped-YYYY-MM-DD` pushed to origin
