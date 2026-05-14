import Foundation
import os

@MainActor
final class AppState: ObservableObject {
    enum State: Equatable {
        case idle
        case recording
        case transcribing
        case cleaning
        case pasting
        case error(SayMooreError)
    }

    @Published private(set) var state: State = .idle

    /// Called after every state transition. Arguments: (previous, next).
    /// **Must NOT call `transition(to:)` recursively** — re-entrant transitions are dropped.
    var onTransition: ((State, State) -> Void)?

    private var isTransitioning = false

    func transition(to next: State) {
        if isTransitioning {
            Log.pipeline.error("AppState re-entrant transition dropped: \(String(describing: self.state), privacy: .public) → \(String(describing: next), privacy: .public)")
            return
        }
        isTransitioning = true
        defer { isTransitioning = false }
        let previous = state
        state = next
        Log.pipeline.debug("AppState \(String(describing: previous), privacy: .public) → \(String(describing: next), privacy: .public)")
        onTransition?(previous, next)
    }
}
