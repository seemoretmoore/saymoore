import Foundation
import UserNotifications

/// Lightweight v1 stub. Full coalescing + menu-bar badge land in Slice 9.
final class NotificationCenterAdapter: @unchecked Sendable {
    static let shared = NotificationCenterAdapter()

    private let center: UNUserNotificationCenter
    private var requestedAuth = false

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func notify(_ error: SayMooreError) {
        let (title, body) = Self.message(for: error)
        deliver(title: title, body: body)
    }

    func notify(title: String, body: String) {
        deliver(title: title, body: body)
    }

    private func deliver(title: String, body: String) {
        Log.app.info("notify: \(title, privacy: .public) — \(body, privacy: .public)")
        ensureAuth()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil
        let req = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(req) { err in
            if let err {
                Log.app.error("UN add failed: \(String(describing: err), privacy: .public)")
            }
        }
    }

    private func ensureAuth() {
        guard !requestedAuth else { return }
        requestedAuth = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, err in
            if let err {
                Log.permissions.error("notification auth error: \(String(describing: err), privacy: .public)")
            }
            Log.permissions.info("notifications granted=\(granted, privacy: .public)")
        }
    }

    static func message(for error: SayMooreError) -> (String, String) {
        switch error {
        case .ollamaUnreachable:
            return ("Ollama not reachable", "Pasted raw transcript. Start Ollama to enable cleanup.")
        case .ollamaModelNotPulled:
            return ("Cleanup model missing", "Run: ollama pull qwen2.5:7b-instruct")
        case .cleanupTimedOut:
            return ("Cleanup timed out", "Pasted raw transcript.")
        case .cleanupFailed:
            return ("Cleanup failed", "Pasted raw transcript.")
        case .pasteFocusChanged:
            return ("Focus changed", "Recording discarded — focus moved before paste.")
        case .pasteClipboardContended:
            return ("Clipboard contended", "Recording discarded — clipboard was modified.")
        case .transcriptionGarbage:
            return ("No speech detected", "Recording discarded.")
        case .modelCorrupted:
            return ("Model corrupted", "Restart SayMoore to re-download.")
        case .silentCapture:
            return ("No audio captured", "Recording produced no audio — try again.")
        case .recordingTooLong:
            return ("Recording too long", "Recording stopped at the 90-second limit.")
        case .recordingLengthWarning:
            return ("Recording almost full", "10 seconds remaining before auto-stop.")
        case .ollamaEndpointUntrusted:
            return ("Ollama endpoint untrusted", "An unknown process is listening on port 11434. Dictation is disabled.")
        case .micPermissionDenied:
            return ("Mic permission denied", "Grant microphone access in System Settings → Privacy & Security.")
        case .audioEngineFailed:
            return ("Audio engine failed", "Could not start recording. Check audio devices and try again.")
        case .permissionRevokedMidSession(let permission):
            switch permission {
            case .microphone:
                return ("Mic permission revoked", "Recording stopped. Grant microphone access in System Settings → Privacy & Security → Microphone.")
            case .accessibility:
                return ("Accessibility permission revoked", "Grant access in System Settings → Privacy & Security → Accessibility.")
            case .inputMonitoring:
                return ("Input Monitoring permission revoked", "Grant access in System Settings → Privacy & Security → Input Monitoring.")
            }
        case .watchdogTimeout:
            return ("Recording stuck", "SayMoore reset itself after 30 seconds without progress. Try again.")
        case .commandRewriteFailed:
            return ("Command Mode failed", "Couldn't rewrite the prior paste. The original text is unchanged.")
        default:
            return ("SayMoore error", String(describing: error))
        }
    }
}
