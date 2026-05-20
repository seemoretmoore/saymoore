# Manual Tests — Slice 10: Permissions Wizard

## Prerequisites
- A second macOS user account (or revoke all permissions for the main account via Privacy & Security)
- App built and installed at /Applications/SayMoore.app

## Test cases

### MT-10-1: Fresh account — full walkthrough
1. Log in as test user (or revoke all SayMoore permissions)
2. Launch SayMoore
3. **Expected:** Wizard appears before any other window; step 1 (Microphone) is active
4. Click "Open Settings" → System Settings > Privacy & Security > Microphone opens
5. Toggle SayMoore on
6. Return to wizard
7. **Expected:** Step 1 shows green checkmark; step 2 (Accessibility) is now active
8. Click "Open Settings" → Accessibility pane opens
9. Add/toggle SayMoore
10. Return → step 3 (Input Monitoring) active
11. Repeat for Input Monitoring
12. **Expected:** Step 4 (Notifications optional) becomes active
13. Click "Open Settings" → Notifications pane opens
14. Grant or skip
15. **Expected:** Wizard closes; model download begins

### MT-10-2: "I opened Settings myself" button
1. Revoke all permissions, launch SayMoore
2. On step 1, open Settings manually (not via button)
3. Grant Microphone in Settings
4. Return to wizard; click "I opened Settings myself"
5. **Expected:** Step 1 shows green checkmark; wizard advances to step 2

### MT-10-3: Window focus re-check
1. Revoke all permissions, launch SayMoore
2. On step 2 (Accessibility), open Settings manually
3. Grant Accessibility in Settings
4. Click back to the wizard window
5. **Expected:** Without pressing any button, wizard auto-advances to step 3 within ~1.5s

### MT-10-4: Skip Notifications
1. Complete steps 1-3; step 4 appears
2. Click "Skip for now"
3. **Expected:** Wizard closes; model download begins

### MT-10-5: Notifications step re-appears on next launch
1. After MT-10-4 (notifications skipped), quit and relaunch
2. **Expected:** Wizard re-appears at step 4 (Notifications) since steps 1-3 are granted

### MT-10-6: Revoke mid-session permission, relaunch
1. Complete wizard fully; use app briefly
2. In System Settings, revoke Accessibility
3. Quit and relaunch SayMoore
4. **Expected:** Wizard re-appears at step 2 (Accessibility)

### MT-10-7: All permissions already granted
1. Complete wizard; quit; relaunch
2. **Expected:** Wizard does NOT appear; app goes directly to model download (or pipeline if model already downloaded)

### MT-10-8: Quit button
1. Revoke all permissions; launch SayMoore
2. Click "Quit" in the wizard
3. **Expected:** App terminates cleanly
