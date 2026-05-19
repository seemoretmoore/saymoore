import Foundation

/// Per-frame VAD classification. Frame width is fixed at 512 samples / 32 ms at 16 kHz —
/// the native frame size of the Silero VAD v5 ONNX model.
enum VADFrameClass: Sendable, Equatable {
    case speech
    case silence
}

/// Stateful voice-activity detector that classifies a single 32 ms frame at a time.
/// Implementations may carry internal model state (e.g. LSTM hidden state) across
/// calls within a single recording, so a fresh recording should use a fresh instance
/// or call `reset()` first.
protocol VADBackend: AnyObject, Sendable {
    /// Classify a single frame. `frame.count` MUST equal 512.
    /// Implementations may throw on malformed input but must not throw for any valid frame.
    func classify(_ frame: [Float]) throws -> VADFrameClass

    /// Reset any internal state. Called between recordings.
    func reset()
}

/// Deterministic test backend: returns a canned sequence of classifications,
/// looping if the consumer calls more times than the canned list provides.
final class FakeVADBackend: VADBackend, @unchecked Sendable {
    private let canned: [VADFrameClass]
    private let lock = NSLock()
    private var cursor = 0
    private(set) var classifyCalls = 0

    init(canned: [VADFrameClass]) {
        precondition(!canned.isEmpty, "FakeVADBackend requires at least one canned classification")
        self.canned = canned
    }

    func classify(_ frame: [Float]) throws -> VADFrameClass {
        lock.lock()
        defer { lock.unlock() }
        classifyCalls += 1
        let cls = canned[cursor % canned.count]
        cursor += 1
        return cls
    }

    func reset() {
        lock.lock()
        cursor = 0
        lock.unlock()
    }
}
