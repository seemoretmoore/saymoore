import Foundation

/// Per-pass sliding-window timing for `StreamingTranscriber`.
/// Persisted in UserDefaults under `streaming.partials.mode`.
enum StreamingMode: String, CaseIterable, Sendable {
    case off
    case balanced
    case responsive

    static let `default`: StreamingMode = .balanced
    static let userDefaultsKey = "streaming.partials.mode"

    var intervalSeconds: TimeInterval {
        switch self {
        case .off:        return 0
        case .balanced:   return 1.5
        case .responsive: return 0.75
        }
    }

    var windowSeconds: TimeInterval {
        switch self {
        case .off:        return 0
        case .balanced:   return 10
        case .responsive: return 8
        }
    }

    var commitAdvanceSeconds: TimeInterval {
        switch self {
        case .off:        return 0
        case .balanced:   return 5
        case .responsive: return 4
        }
    }

    var windowSamples: Int { Int(windowSeconds * 16_000) }
    var commitAdvanceSamples: Int { Int(commitAdvanceSeconds * 16_000) }
}
