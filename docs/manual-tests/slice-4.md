# Slice 4 — Manual Test Sign-off (Per-app overrides + hot-reload)

Goal: verify per-app cleanup presets resolve by bundle ID, that `~/Library/Application Support/SayMoore/presets.json` hot-reloads on edit (including atomic-rename saves), and that malformed JSON falls back to last-good config.

Signed off **2026-05-14** on macOS Sonoma 14.

## Bundled override scope

Final bundled `presets.example.json` ships `default` plus four overrides:

| Bundle ID | App |
|---|---|
| `com.tinyspeck.slackmacgap` | Slack |
| `com.barebones.bbedit` | BBEdit |
| `com.apple.Notes` | Notes |
| `com.apple.MobileSMS` | Messages |

Apple Mail (`com.apple.mail`) and Xcode (`com.apple.dt.Xcode`) were considered but dropped:
- **Mail**: not part of seemoretmoore's workflow (Gmail in browser). A browser-based override is deferred.
- **Xcode**: BBEdit is the actual daily code/text editor; Xcode is only opened to develop SayMoore itself. The same technical-preservation prompt applies under the BBEdit bundle ID.

## Part A — per-app dictation matrix

Two phrases used: a casual matrix phrase (Slack/Notes/Messages/browser default) and a technical phrase to exercise BBEdit's identifier/acronym handling.

**Casual phrase:** "hi seemoretmoore uh i think we should ship friday and also fix the api timeout"

| # | App | Bundle ID | Cleaned output | Pass |
|---|---|---|---|---|
| 1 | Slack | `com.tinyspeck.slackmacgap` | `hi seemoretmoore, i think we should ship friday and also fix the api timeout` | ✅ |
| 2 | Browser / Gmail web | (default fallback) | `Hi seemoretmoore, I think we should ship on Friday and also fix the API timeout.` | ✅ (correct default behavior — browser bundle ID has no override) |
| 3 | Notes | `com.apple.Notes` | `Hi seemoretmoore, I think we should ship on Friday and also fix the API timeout.` | ✅ (Notes prompt is intentionally default-shaped) |
| 4 | Messages | `com.apple.MobileSMS` | `hi seemoretmoore, i think we should ship on friday and also fix the api timeout` | ✅ |

**Technical phrase (BBEdit differentiation):** "fix the get user request and update the json schema before calling api endpoint"

| App | Bundle ID | Cleaned output | Pass |
|---|---|---|---|
| BBEdit | `com.barebones.bbedit` | `Fix getUserRequest and update JSON schema before calling API endpoint` | ✅ — dropped article, camelCased identifier, no trailing period |
| Notes (control) | `com.apple.Notes` | `Fix the get user request and update the JSON schema before calling API endpoint.` | ✅ — sentence-cased, period, no camelCase |

Per-app preset resolution proven by log lines like `cleanup → preset=com.barebones.bbedit` for each dictation.

## Part B — hot-reload

All three editor scenarios fired `presets.json reloaded`:

| # | Editor | Save mode | Pass |
|---|---|---|---|
| H1 | VSCode | atomic temp-rename | ✅ |
| H2 | BBEdit | atomic temp-rename | ✅ |
| H3 | vim | in-place write (`:w`) | ✅ |

The FSEvents watcher on the parent directory catches both write styles, as designed.

## Part C — failure modes

The "Invalid presets.json — Using last-good config." notification banner fired for each failure case, and last-good preset continued to resolve on subsequent dictations.

| # | Action | Banner? | Pass |
|---|---|---|---|
| F1 | Deleted final `}` in VSCode and saved | ✅ banner | ✅ |
| F2 | Restored `}` | (silent reload) | ✅ |
| F3 | Removed top-level `"default"` key | ✅ banner | ✅ |
| F4 | `rm` on live `presets.json` while app running | ✅ banner | ✅ |

After F4, relaunched the app — `presets.json` was re-materialised from the bundled example with all 4 overrides. Verified with `jq '.overrides | keys'`.

## Sign-off

- [x] Per-app preset resolution by bundle ID works (logs + visible differentiation).
- [x] Hot-reload fires for atomic-rename writes (VSCode/BBEdit) AND in-place writes (vim).
- [x] Malformed JSON / missing default / deleted file all fall back to last-good + show banner.
- [x] Fresh launch with deleted `presets.json` re-materialises from the bundled example.
- [x] Ready to start Slice 5 (VAD + length cap).
