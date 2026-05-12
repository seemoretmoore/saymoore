import Foundation

enum HotkeyEvent: Equatable {
    case ctrlDown(at: TimeInterval)
    case ctrlUp(at: TimeInterval)
    case otherKey(at: TimeInterval)
}

enum HotkeyOutput: Equatable {
    case none
    case toggle
}

struct HotkeyRecognizer {
    static let maxGapSeconds: TimeInterval = 0.300

    private enum Phase {
        case idle
        case firstDown
        case firstUp(upAt: TimeInterval)
    }

    private var phase: Phase = .idle

    mutating func process(_ event: HotkeyEvent) -> HotkeyOutput {
        switch (phase, event) {
        case (.idle, .ctrlDown):
            phase = .firstDown
            return .none

        case (.idle, _):
            return .none

        case (.firstDown, .ctrlUp(let t)):
            phase = .firstUp(upAt: t)
            return .none

        case (.firstDown, .ctrlDown):
            // Held / synthetic re-down — stay armed.
            return .none

        case (.firstDown, .otherKey):
            phase = .idle
            return .none

        case (.firstUp(let upAt), .ctrlDown(let downAt)):
            if downAt - upAt <= Self.maxGapSeconds {
                phase = .idle
                return .toggle
            } else {
                phase = .firstDown
                return .none
            }

        case (.firstUp, .ctrlUp):
            return .none

        case (.firstUp, .otherKey):
            phase = .idle
            return .none
        }
    }
}
