import Foundation
import os

/// Consumes 16 kHz mono PCM samples, batches them into 32 ms / 512-sample frames,
/// runs a `VADBackend` on each frame, and tracks consecutive-silence duration.
/// Fires `silenceObserver` exactly once when accumulated silence first crosses
/// `silenceThreshold` during the current armed period.
///
/// Designed so `feed(_:)` can be called from any thread (including the audio
/// tap thread): the call does a single small copy + async dispatch and returns
/// immediately. Classification runs on a serial worker queue.
final class VADService: @unchecked Sendable {
    /// Sample rate the service expects. Matches `AudioRecorder.targetSampleRate`.
    static let sampleRate: Int = 16_000
    /// Frame width = 512 samples = 32 ms at 16 kHz (Silero v5 native).
    static let frameSamples: Int = SileroFrameSamples
    /// Frame duration in seconds.
    static let frameDuration: TimeInterval = Double(frameSamples) / Double(sampleRate)
    /// Hangover: silence frames only start accumulating after this many consecutive
    /// silence classifications. Prevents brief acoustic dips inside an utterance
    /// from prematurely starting the silence count.
    static let silenceHangoverFrames: Int = 3

    private let backend: VADBackend
    private let silenceThreshold: TimeInterval
    private let worker = DispatchQueue(label: "com.seemoretmoore.saymoore.vad", qos: .userInitiated)

    private let lock = NSLock()
    // Carry-over samples that didn't fill a complete frame on the last feed.
    private var pendingSamples: [Float] = []
    // Consecutive .silence classifications observed (pre-hangover).
    private var consecutiveSilenceClassifications: Int = 0
    // Accumulated silence frames after hangover is satisfied. One frame = 32 ms.
    private var silenceFrames: Int = 0
    // True once silenceObserver has fired for this armed period; reset() rearms.
    private var thresholdFired: Bool = false

    /// Fires exactly once when accumulated silence first crosses `silenceThreshold`.
    /// Reset by calling `reset()` (typically at recording start).
    /// Called on the worker queue — observers should hop to the main actor if
    /// they touch UI state.
    var silenceObserver: (@Sendable () -> Void)?

    init(backend: VADBackend, silenceThreshold: TimeInterval = 10.0) {
        self.backend = backend
        self.silenceThreshold = silenceThreshold
    }

    /// Current accumulated silence duration in seconds. Reset on any speech frame
    /// or on `reset()`. Hangover frames do not contribute.
    var silenceDuration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Double(silenceFrames) * Self.frameDuration
    }

    /// Feed PCM samples (16 kHz mono). Any chunk size is accepted; the service
    /// buffers partial frames internally. Returns immediately; classification
    /// runs async on the worker queue.
    func feed(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        worker.async { [self] in
            self.processFrames(samples)
        }
    }

    /// Block until all pending `feed` work has been processed. Primarily for tests
    /// and for the synchronous-stop path; harmless in production.
    func waitForPendingWork() {
        worker.sync { }
    }

    /// Reset all state: pending buffer, silence counter, threshold-fired flag,
    /// and the backend's internal state. Call at the start of each recording.
    /// Synchronously drains the worker queue so post-reset feeds start from clean state.
    func reset() {
        worker.sync { [self] in
            self.lock.lock()
            self.pendingSamples.removeAll(keepingCapacity: true)
            self.consecutiveSilenceClassifications = 0
            self.silenceFrames = 0
            self.thresholdFired = false
            self.lock.unlock()
            self.backend.reset()
        }
    }

    // MARK: - Private

    private func processFrames(_ incoming: [Float]) {
        // Combine with any leftover from the prior feed.
        lock.lock()
        var buffer = pendingSamples
        pendingSamples.removeAll(keepingCapacity: true)
        lock.unlock()

        buffer.append(contentsOf: incoming)
        let frameSize = Self.frameSamples

        var offset = 0
        while buffer.count - offset >= frameSize {
            let frame = Array(buffer[offset..<(offset + frameSize)])
            offset += frameSize

            let cls: VADFrameClass
            do {
                cls = try backend.classify(frame)
            } catch {
                // Log and skip this frame — don't let a single bad frame stop the loop.
                Log.vad.error("VAD classify failed: \(String(describing: error), privacy: .public)")
                continue
            }
            handleClassification(cls)
        }

        // Save any tail samples for the next feed.
        if offset < buffer.count {
            let leftover = Array(buffer[offset..<buffer.count])
            lock.lock()
            pendingSamples = leftover
            lock.unlock()
        }
    }

    private func handleClassification(_ cls: VADFrameClass) {
        let shouldFireObserver: Bool

        lock.lock()
        switch cls {
        case .speech:
            consecutiveSilenceClassifications = 0
            silenceFrames = 0
            shouldFireObserver = false
        case .silence:
            consecutiveSilenceClassifications += 1
            if consecutiveSilenceClassifications > Self.silenceHangoverFrames {
                silenceFrames += 1
            }
            let currentSilence = Double(silenceFrames) * Self.frameDuration
            if !thresholdFired && currentSilence >= silenceThreshold {
                thresholdFired = true
                shouldFireObserver = true
            } else {
                shouldFireObserver = false
            }
        }
        lock.unlock()

        if shouldFireObserver {
            silenceObserver?()
        }
    }
}
