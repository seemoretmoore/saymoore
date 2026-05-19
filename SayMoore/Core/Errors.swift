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
    case recordingTooLong
    case recordingLengthWarning
    case silentCapture
    case ollamaEndpointUntrusted

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
    // Exhaustive switch. Adding a new case to SayMooreError forces a new
    // discriminant arm here at compile time — the missing-`==`-arm footgun
    // that the prior `default: false` impl hid is now a build error.
    private var discriminant: Int {
        switch self {
        case .micPermissionDenied: return 0
        case .audioEngineFailed: return 1
        case .transcriptionFailed: return 2
        case .transcriptionGarbage: return 3
        case .cleanupTimedOut: return 4
        case .cleanupFailed: return 5
        case .ollamaUnreachable: return 6
        case .ollamaModelNotPulled: return 7
        case .pasteFocusChanged: return 8
        case .pasteClipboardContended: return 9
        case .pasteInjectionFailed: return 10
        case .modelMissing: return 11
        case .modelCorrupted: return 12
        case .diskFull: return 13
        case .watchdogTimeout: return 14
        case .recordingTooLong: return 15
        case .silentCapture: return 16
        case .permissionRevokedMidSession: return 17
        case .ollamaEndpointUntrusted: return 18
        case .recordingLengthWarning: return 19
        }
    }

    static func == (lhs: SayMooreError, rhs: SayMooreError) -> Bool {
        guard lhs.discriminant == rhs.discriminant else { return false }
        switch (lhs, rhs) {
        case let (.audioEngineFailed(a), .audioEngineFailed(b)),
             let (.transcriptionFailed(a), .transcriptionFailed(b)),
             let (.cleanupFailed(a), .cleanupFailed(b)):
            return errorsEqual(a, b)
        case let (.pasteFocusChanged(ca, cua), .pasteFocusChanged(cb, cub)):
            return ca == cb && cua == cub
        case let (.permissionRevokedMidSession(a), .permissionRevokedMidSession(b)):
            return a == b
        default:
            // Same discriminant + no payload arm matched ⇒ payload-free case ⇒ equal.
            return true
        }
    }

    private static func errorsEqual(_ a: Error, _ b: Error) -> Bool {
        let na = a as NSError
        let nb = b as NSError
        return na.domain == nb.domain && na.code == nb.code
    }
}
