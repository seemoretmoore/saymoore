import Foundation

protocol NotificationSink: Sendable {
    func send(title: String, body: String)
}

extension NotificationCenterAdapter: NotificationSink {
    func send(title: String, body: String) { notify(title: title, body: body) }
}

@MainActor
final class NotificationCoordinator {
    struct Badge: Equatable {
        let key: ErrorClass
        let label: String
    }

    enum ErrorClass: Hashable {
        case ollamaUnreachable, ollamaModelNotPulled, ollamaEndpointUntrusted
        case micPermissionDenied, permissionRevoked(SayMooreError.Permission)
        case audioEngineFailed, modelCorrupted, modelMissing
        case diskFull, watchdogTimeout
        case transcriptionFailed, transcriptionGarbage
        case cleanupTimedOut, cleanupFailed
        case pasteFocusChanged, pasteClipboardContended, pasteInjectionFailed
        case silentCapture, recordingTooLong, recordingLengthWarning

        var persistentBadgeLabel: String? {
            switch self {
            case .ollamaUnreachable: return "Ollama down"
            case .ollamaModelNotPulled: return "Cleanup model missing"
            case .ollamaEndpointUntrusted: return "Ollama endpoint untrusted"
            case .micPermissionDenied: return "Mic blocked"
            case .permissionRevoked(let p): return "Permission revoked: \(p.rawValue)"
            case .modelCorrupted: return "Whisper model corrupted"
            case .modelMissing: return "Whisper model missing"
            case .audioEngineFailed, .diskFull, .watchdogTimeout,
                 .transcriptionFailed, .transcriptionGarbage,
                 .cleanupTimedOut, .cleanupFailed,
                 .pasteFocusChanged, .pasteClipboardContended, .pasteInjectionFailed,
                 .silentCapture, .recordingTooLong, .recordingLengthWarning:
                return nil
            }
        }
    }

    static let defaultCooldown: Duration = .seconds(60)
    static let shared = NotificationCoordinator()

    private let sink: NotificationSink
    private let cooldown: Duration
    private let now: () -> ContinuousClock.Instant
    private var lastSent: [ErrorClass: ContinuousClock.Instant] = [:]
    private(set) var badge: Badge? {
        didSet { if oldValue != badge { onBadgeChange?(badge) } }
    }
    var onBadgeChange: ((Badge?) -> Void)?

    init(
        sink: NotificationSink = NotificationCenterAdapter.shared,
        cooldown: Duration = NotificationCoordinator.defaultCooldown,
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.sink = sink
        self.cooldown = cooldown
        self.now = now
    }

    func notify(_ error: SayMooreError) {
        let cls = Self.classify(error)
        let (title, body) = NotificationCenterAdapter.message(for: error)
        if let last = lastSent[cls], now() - last < cooldown {
            Log.app.debug("NotificationCoordinator coalesced: \(String(describing: cls), privacy: .public)")
        } else {
            sink.send(title: title, body: body)
            lastSent[cls] = now()
        }
        if let label = cls.persistentBadgeLabel {
            badge = Badge(key: cls, label: label)
        }
    }

    func notify(title: String, body: String) {
        sink.send(title: title, body: body)
    }

    func clearBadge(for error: SayMooreError) {
        let cls = Self.classify(error)
        if badge?.key == cls { badge = nil }
    }

    func clearAllBadges() { badge = nil }

    static func classify(_ e: SayMooreError) -> ErrorClass {
        switch e {
        case .ollamaUnreachable: return .ollamaUnreachable
        case .ollamaModelNotPulled: return .ollamaModelNotPulled
        case .ollamaEndpointUntrusted: return .ollamaEndpointUntrusted
        case .micPermissionDenied: return .micPermissionDenied
        case .permissionRevokedMidSession(let p): return .permissionRevoked(p)
        case .audioEngineFailed: return .audioEngineFailed
        case .modelCorrupted: return .modelCorrupted
        case .modelMissing: return .modelMissing
        case .diskFull: return .diskFull
        case .watchdogTimeout: return .watchdogTimeout
        case .transcriptionFailed: return .transcriptionFailed
        case .transcriptionGarbage: return .transcriptionGarbage
        case .cleanupTimedOut: return .cleanupTimedOut
        case .cleanupFailed: return .cleanupFailed
        case .pasteFocusChanged: return .pasteFocusChanged
        case .pasteClipboardContended: return .pasteClipboardContended
        case .pasteInjectionFailed: return .pasteInjectionFailed
        case .silentCapture: return .silentCapture
        case .recordingTooLong: return .recordingTooLong
        case .recordingLengthWarning: return .recordingLengthWarning
        }
    }

}
