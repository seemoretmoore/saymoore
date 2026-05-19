import AppKit

/// Plays distinct chimes on recording start, natural stop, Esc cancel, and
/// busy-hotkey rejection. Mute state is read once at init from UserDefaults
/// key "audio.feedback.muted".
@MainActor
final class AudioFeedbackService {
    // Seam for testing: inject custom play closures.
    private let playStart:  () -> Void
    private let playStop:   () -> Void
    private let playCancel: () -> Void
    private let playBusy:   () -> Void
    let muted: Bool

    /// Production initializer — uses NSSound system sounds.
    convenience init(
        muted: Bool = UserDefaults.standard.bool(forKey: "audio.feedback.muted")
    ) {
        let startSound  = NSSound(named: "Glass")
        let stopSound   = NSSound(named: "Pop")
        let cancelSound = NSSound(named: "Funk")
        let busySound   = NSSound(named: "Sosumi")
        self.init(
            muted: muted,
            playStart:  { startSound?.play()  },
            playStop:   { stopSound?.play()   },
            playCancel: { cancelSound?.play() },
            playBusy:   { busySound?.play()   }
        )
    }

    /// Dependency-injection initializer for tests.
    init(
        muted: Bool,
        playStart: @escaping () -> Void,
        playStop: @escaping () -> Void,
        playCancel: @escaping () -> Void = {},
        playBusy: @escaping () -> Void = {}
    ) {
        self.muted      = muted
        self.playStart  = playStart
        self.playStop   = playStop
        self.playCancel = playCancel
        self.playBusy   = playBusy
    }

    /// Call from AppState.onTransition. `.recording → .idle` is Esc-cancel
    /// (only `cancel()` routes back to idle); all other recording exits are
    /// natural stop / VAD auto-stop / length-cap.
    func handle(old: AppState.State, new: AppState.State) {
        guard !muted else { return }
        switch (old, new) {
        case (.idle, .recording):
            playStart()
        case (.recording, .idle):
            playCancel()
        case (.recording, _) where new != .recording:
            playStop()
        default:
            break
        }
    }

    /// Fire the busy chime when a hotkey toggle is ignored because the
    /// pipeline is mid-transcribe/clean/paste. Not routed through state
    /// transitions because no transition occurs.
    func busy() {
        guard !muted else { return }
        playBusy()
    }
}
