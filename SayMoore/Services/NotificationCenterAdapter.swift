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
        send(title: title, body: body)
    }

    func notify(title: String, body: String) {
        send(title: title, body: body)
    }

    private func send(title: String, body: String) {
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
            return ("Focus changed", "Your text is on the clipboard — paste manually.")
        case .pasteClipboardContended:
            return ("Clipboard contended", "Your text is on the clipboard — paste manually.")
        case .transcriptionGarbage:
            return ("No speech detected", "Recording discarded.")
        case .modelCorrupted:
            return ("Model corrupted", "Restart SayMoore to re-download.")
        default:
            return ("SayMoore error", String(describing: error))
        }
    }
}
