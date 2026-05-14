import AppKit

/// Plays distinct chimes on recording start/stop.
/// Mute state is read once at init from UserDefaults key "audio.feedback.muted".
@MainActor
final class AudioFeedbackService {
    // Seam for testing: inject custom play closures.
    private let playStart: () -> Void
    private let playStop: () -> Void
    let muted: Bool

    /// Production initializer — uses NSSound system sounds.
    convenience init(
        muted: Bool = UserDefaults.standard.bool(forKey: "audio.feedback.muted")
    ) {
        let startSound = NSSound(named: "Glass")
        let stopSound  = NSSound(named: "Pop")
        self.init(
            muted: muted,
            playStart: { startSound?.play() },
            playStop:  { stopSound?.play()  }
        )
    }

    /// Dependency-injection initializer for tests.
    init(
        muted: Bool,
        playStart: @escaping () -> Void,
        playStop: @escaping () -> Void
    ) {
        self.muted     = muted
        self.playStart = playStart
        self.playStop  = playStop
    }

    /// Call from AppState.onTransition.
    func handle(old: AppState.State, new: AppState.State) {
        guard !muted else { return }
        switch (old, new) {
        case (.idle, .recording):
            playStart()
        case (.recording, _) where new != .recording:
            playStop()
        default:
            break
        }
    }
}
