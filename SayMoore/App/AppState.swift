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
    var onTransition: ((State, State) -> Void)?

    func transition(to next: State) {
        let previous = state
        state = next
        Log.pipeline.debug("AppState \(String(describing: previous), privacy: .public) → \(String(describing: next), privacy: .public)")
        onTransition?(previous, next)
    }
}
