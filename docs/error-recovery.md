# SayMoore Error Recovery Catalog

SayMoore funnels every `SayMooreError` through `NotificationCoordinator`, which
coalesces repeats of the same `ErrorClass` within a 60-second cooldown so a
storm of failures (e.g. five dictations against a dead Ollama) surfaces as a
single banner. Classes that represent unresolved environmental conditions
(Ollama down, model corrupted, permission revoked, …) also raise a persistent
menu-bar badge that stays lit until the condition clears. The pipeline watchdog
is the backstop: if a state transition stalls past its budget, the watchdog
fires `.watchdogTimeout`, the state machine resets to `.idle`, and a banner
explains what happened.

| # | Case | Trigger | Notification title | Notification body | State consequence | Persistent badge | Recovery |
|---|---|---|---|---|---|---|---|
| 0 | `.micPermissionDenied` | Mic access denied at recording start. | Mic permission denied | Grant microphone access in System Settings → Privacy & Security. | Recording attempt aborted → `.idle`. | Yes (`Mic blocked`) | Manual — grant in System Settings. |
| 1 | `.audioEngineFailed(underlying:)` | `AVAudioEngine` start/tap throws (device change, exclusive HAL client, sample-rate mismatch). | Audio engine failed | Could not start recording. Check audio devices and try again. | Recording aborted → `.error(...)` → `.idle`. | No | Manual — user retries; usually fixed by replugging device. |
| 2 | `.transcriptionFailed(underlying:)` | whisper.cpp throws or returns an unusable result. | SayMoore error | (default formatter) | `.transcribing` → `.error(...)` → `.idle`. | No | Manual — user re-records. **Gap:** no bespoke copy in `message(for:)`. |
| 3 | `.transcriptionGarbage` | Transcript matches the garbage denylist (per Slice 8). | No speech detected | Recording discarded. | `.transcribing` → `.error(...)` → `.idle`; nothing pasted. | No | Automatic — discarded; user re-records. |
| 4 | `.cleanupTimedOut` | Ollama cleanup exceeds budget. | Cleanup timed out | Pasted raw transcript. | Falls back to raw paste, then `.idle`. | No | Automatic — raw transcript pasted. |
| 5 | `.cleanupFailed(underlying:)` | Ollama returns an error mid-cleanup. | Cleanup failed | Pasted raw transcript. | Falls back to raw paste, then `.idle`. | No | Automatic — raw transcript pasted. |
| 6 | `.ollamaUnreachable` | `tags()` probe fails — daemon not running / port closed. | Ollama not reachable | Pasted raw transcript. Start Ollama to enable cleanup. | Falls back to raw paste, then `.idle`. | Yes (`Ollama down`) | Automatic paste + manual recovery (start Ollama, optionally via `OllamaSupervisor` cold-spawn). |
| 7 | `.ollamaModelNotPulled` | Cleanup model absent from local Ollama. | Cleanup model missing | Run: ollama pull qwen2.5:7b-instruct | Falls back to raw paste, then `.idle`. | Yes (`Cleanup model missing`) | Manual — `ollama pull qwen2.5:7b-instruct`. |
| 8 | `.pasteFocusChanged(captured:current:)` | Focused app/field changed between capture and paste. | Focus changed | Recording discarded — focus moved before paste. | `.pasting` → `.error(...)` → `.idle`; nothing pasted. | No | Manual — user re-records with focus held. |
| 9 | `.pasteClipboardContended` | Clipboard mutated by another app during paste. | Clipboard contended | Recording discarded — clipboard was modified. | `.pasting` → `.error(...)` → `.idle`; nothing pasted. | No | Manual — user re-records. |
| 10 | `.pasteInjectionFailed` | Cmd-V injection (CGEvent) failed. | SayMoore error | (default formatter) | `.pasting` → `.error(...)` → `.idle`. | No | Manual — user re-records. **Gap:** no bespoke copy in `message(for:)`. |
| 11 | `.modelMissing` | Whisper model file absent at bootstrap. | SayMoore error | (default formatter) | Bootstrap blocked; download window presented. | Yes (`Whisper model missing`) | Manual — re-download via in-app window. **Gap:** no bespoke copy in `message(for:)`. |
| 12 | `.modelCorrupted` | Whisper model fails integrity check at bootstrap. | Model corrupted | Restart SayMoore to re-download. | Bootstrap blocked; download window presented on relaunch. | Yes (`Whisper model corrupted`) | Manual — relaunch app to re-download. Corruption introduced mid-session is out of scope for Slice 9. |
| 13 | `.diskFull` | Write to recording scratch / model dir fails ENOSPC. | SayMoore error | (default formatter) | Pipeline aborts → `.idle`. | No | Manual — free disk space. **Gap:** no bespoke copy in `message(for:)`. |
| 14 | `.watchdogTimeout` | Pipeline watchdog (30s prod, 0.2s tests) fires on any stuck transition. | Recording stuck | SayMoore reset itself after 30 seconds without progress. Try again. | Forced reset → `.idle`. | No | Automatic — state machine reset; user re-records. |
| 15 | `.recordingTooLong` | Recording hits the 90s hard cap (Slice 5). | Recording too long | Recording stopped at the 90-second limit. | `.recording` → stop → continues through transcription/cleanup/paste. | No | Automatic — recording auto-stops and pipeline proceeds. |
| 16 | `.recordingLengthWarning` | 80s mark reached (10s before cap). | Recording almost full | 10 seconds remaining before auto-stop. | Stays in `.recording`. | No | Automatic — informational; user can stop now. |
| 17 | `.silentCapture` | Recording produced no audio samples / RMS below floor. | No audio captured | Recording produced no audio — try again. | `.recording` → `.error(...)` → `.idle`. | No | Manual — user retries. |
| 18 | `.ollamaEndpointUntrusted` | `http://127.0.0.1:11434` answers but does not look like Ollama (unknown listener). | Ollama endpoint untrusted | An unknown process is listening on port 11434. Dictation is disabled. | Cleanup disabled; pipeline either skips cleanup or aborts. | Yes (`Ollama endpoint untrusted`) | Manual — kill rogue listener, restart Ollama. |
| 19 | `.permissionRevokedMidSession(.microphone)` | Mic permission revoked while app running. | Mic permission revoked | Recording stopped. Grant microphone access in System Settings → Privacy & Security → Microphone. | Active recording cancelled → `.idle`. | Yes (`Permission revoked: microphone`) | Manual — re-grant in System Settings. |
| 20 | `.permissionRevokedMidSession(.accessibility)` | Accessibility permission revoked while app running. | Accessibility permission revoked | Grant access in System Settings → Privacy & Security → Accessibility. | Pipeline aborts before paste → `.idle`. | Yes (`Permission revoked: accessibility`) | Manual — re-grant in System Settings. |
| 21 | `.permissionRevokedMidSession(.inputMonitoring)` | Input Monitoring permission revoked while app running. | Input Monitoring permission revoked | Grant access in System Settings → Privacy & Security → Input Monitoring. | Hotkey listener disabled; pipeline → `.idle`. | Yes (`Permission revoked: inputMonitoring`) | Manual — re-grant in System Settings. |

## Copy gaps (Slice 9 follow-up candidates)

The following cases currently render through the generic `default` arm in
`NotificationCenterAdapter.message(for:)` and surface as
`("SayMoore error", String(describing: error))` — fine for engineers but
unhelpful to users:

- `.transcriptionFailed`
- `.pasteInjectionFailed`
- `.modelMissing`
- `.diskFull`
- `.watchdogTimeout`

Add bespoke copy in a future slice if/when any of these become observable in
the field.
