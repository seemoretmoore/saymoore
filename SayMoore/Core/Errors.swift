import Foundation

enum SayMooreError: Error {
    case micPermissionDenied
    case audioEngineFailed(underlying: Error)
    case transcriptionFailed(underlying: Error)
    case transcriptionGarbage
    case cleanupTimedOut
    case cleanupFailed(underlying: Error)
    case ollamaUnreachable
    case ollamaModelNotPulled
    case pasteFocusChanged(captured: String?, current: String?)
    case pasteClipboardContended
    case pasteInjectionFailed
    case modelMissing
    case modelCorrupted
    case diskFull
    case watchdogTimeout

    enum Permission: String, Sendable {
        case microphone, accessibility, inputMonitoring
    }
    case permissionRevokedMidSession(Permission)
}

extension SayMooreError {
    /// Whether the pipeline should swallow this error and paste the raw transcript.
    var fallsBackToRaw: Bool {
        switch self {
        case .cleanupTimedOut, .cleanupFailed, .ollamaUnreachable, .ollamaModelNotPulled:
            return true
        default:
            return false
        }
    }
}

extension SayMooreError: Equatable {
    static func == (lhs: SayMooreError, rhs: SayMooreError) -> Bool {
        switch (lhs, rhs) {
        case (.micPermissionDenied, .micPermissionDenied),
             (.transcriptionGarbage, .transcriptionGarbage),
             (.cleanupTimedOut, .cleanupTimedOut),
             (.ollamaUnreachable, .ollamaUnreachable),
             (.ollamaModelNotPulled, .ollamaModelNotPulled),
             (.pasteClipboardContended, .pasteClipboardContended),
             (.pasteInjectionFailed, .pasteInjectionFailed),
             (.modelMissing, .modelMissing),
             (.modelCorrupted, .modelCorrupted),
             (.diskFull, .diskFull),
             (.watchdogTimeout, .watchdogTimeout):
            return true
        case let (.audioEngineFailed(a), .audioEngineFailed(b)):
            return String(describing: a) == String(describing: b)
        case let (.transcriptionFailed(a), .transcriptionFailed(b)):
            return String(describing: a) == String(describing: b)
        case let (.cleanupFailed(a), .cleanupFailed(b)):
            return String(describing: a) == String(describing: b)
        case let (.pasteFocusChanged(ca, cua), .pasteFocusChanged(cb, cub)):
            return ca == cb && cua == cub
        case let (.permissionRevokedMidSession(a), .permissionRevokedMidSession(b)):
            return a == b
        default:
            return false
        }
    }
}
