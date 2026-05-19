import XCTest
import os
@testable import SayMoore

/// Sendable counter for use inside @Sendable observer closures under strict
/// concurrency. Wraps an unfair lock + Int.
private final class Counter: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<Int>(initialState: 0)
    func increment() -> Int { lock.withLock { $0 += 1; return $0 } }
    var value: Int { lock.withLock { $0 } }
}

/// Sendable boolean flag, same pattern.
private final class Flag: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<Bool>(initialState: false)
    func set() { lock.withLock { $0 = true } }
    var isSet: Bool { lock.withLock { $0 } }
}

final class VADServiceTests: XCTestCase {

    private let frameSamples = VADService.frameSamples
    private let frameDuration = VADService.frameDuration

    /// Generate `count` samples representing `n` full frames of one class.
    private func samples(forFrames n: Int) -> [Float] {
        Array(repeating: Float(0), count: n * frameSamples)
    }

    // MARK: - Silence counter

    func testSilenceCounterIncrementsAfterHangover() throws {
        // Backend that says .silence every time.
        let backend = FakeVADBackend(canned: [.silence])
        let svc = VADService(backend: backend, silenceThreshold: 10)

        // Feed enough samples for 10 frames worth.
        svc.feed(samples(forFrames: 10))
        drainWorker(svc)

        // Hangover swallows the first 3 silence frames; frames 4-10 count.
        // silenceDuration = (10 - 3) * 32ms = 224ms.
        let expected = Double(10 - VADService.silenceHangoverFrames) * frameDuration
        XCTAssertEqual(svc.silenceDuration, expected, accuracy: 1e-6)
    }

    func testSpeechFrameResetsSilenceCounter() throws {
        // Pattern: 5 silences, 1 speech, 5 silences.
        let backend = FakeVADBackend(canned: [.silence, .silence, .silence, .silence, .silence,
                                              .speech,
                                              .silence, .silence, .silence, .silence, .silence])
        let svc = VADService(backend: backend, silenceThreshold: 10)

        svc.feed(samples(forFrames: 11))
        drainWorker(svc)

        // After the speech frame, counter reset to 0. Then 5 more silences:
        // hangover swallows 3, so 2 count.
        let expected = Double(5 - VADService.silenceHangoverFrames) * frameDuration
        XCTAssertEqual(svc.silenceDuration, expected, accuracy: 1e-6)
    }

    // MARK: - Threshold-crossing observer

    func testSilenceObserverFiresOnceWhenThresholdCrossed() throws {
        let backend = FakeVADBackend(canned: [.silence])
        // Threshold = 5 frames worth of silence post-hangover = 5 * 32ms = 0.16s.
        let threshold = 5 * frameDuration
        let svc = VADService(backend: backend, silenceThreshold: threshold)

        let exp = expectation(description: "silence observer fires")
        let firings = Counter()
        svc.silenceObserver = {
            _ = firings.increment()
            exp.fulfill()
        }

        // Feed 20 frames — well over threshold. Observer should fire exactly once.
        svc.feed(samples(forFrames: 20))
        wait(for: [exp], timeout: 1.0)
        drainWorker(svc)

        XCTAssertEqual(firings.value, 1, "observer must fire exactly once per armed period")
    }

    func testSilenceObserverDoesNotFireBelowThreshold() throws {
        let backend = FakeVADBackend(canned: [.silence])
        // Threshold = 100 frames worth (way more than we'll feed).
        let threshold = 100 * frameDuration
        let svc = VADService(backend: backend, silenceThreshold: threshold)

        let fired = Flag()
        svc.silenceObserver = { fired.set() }

        svc.feed(samples(forFrames: 10))
        drainWorker(svc)

        XCTAssertFalse(fired.isSet)
    }

    func testSilenceObserverRearmsAfterReset() throws {
        let backend = FakeVADBackend(canned: [.silence])
        let threshold = 5 * frameDuration
        let svc = VADService(backend: backend, silenceThreshold: threshold)

        let exp1 = expectation(description: "first crossing")
        let exp2 = expectation(description: "second crossing after reset")
        let firings = Counter()
        svc.silenceObserver = {
            let n = firings.increment()
            if n == 1 { exp1.fulfill() }
            if n == 2 { exp2.fulfill() }
        }

        svc.feed(samples(forFrames: 20))
        wait(for: [exp1], timeout: 1.0)

        svc.reset()
        XCTAssertEqual(svc.silenceDuration, 0)

        svc.feed(samples(forFrames: 20))
        wait(for: [exp2], timeout: 1.0)

        XCTAssertEqual(firings.value, 2)
    }

    // MARK: - Partial-frame buffering

    func testPartialFramesAreBufferedAcrossFeeds() throws {
        let backend = FakeVADBackend(canned: [.silence])
        let svc = VADService(backend: backend, silenceThreshold: 100) // never crosses

        // Feed half a frame at a time, six times. Should accumulate 3 frames.
        let halfFrame = Array(repeating: Float(0), count: frameSamples / 2)
        for _ in 0..<6 { svc.feed(halfFrame) }
        drainWorker(svc)

        // 3 frames classified. Hangover swallows the first 3, so silenceFrames = 0.
        XCTAssertEqual(backend.classifyCalls, 3)
        XCTAssertEqual(svc.silenceDuration, 0, accuracy: 1e-9)
    }

    func testFeedEmptyArrayIsNoOp() throws {
        let backend = FakeVADBackend(canned: [.silence])
        let svc = VADService(backend: backend)
        svc.feed([])
        drainWorker(svc)
        XCTAssertEqual(backend.classifyCalls, 0)
    }

    // MARK: - Reset clears state

    func testResetClearsPendingSamples() throws {
        let backend = FakeVADBackend(canned: [.silence])
        let svc = VADService(backend: backend, silenceThreshold: 100)

        // Feed 1.5 frames — half stays pending.
        svc.feed(Array(repeating: Float(0), count: frameSamples + frameSamples / 2))
        drainWorker(svc)
        XCTAssertEqual(backend.classifyCalls, 1) // 1 full frame classified, half pending

        svc.reset()

        // Feed another half frame — would have completed a frame combined with
        // the prior leftover, but reset cleared it. No classification yet.
        svc.feed(Array(repeating: Float(0), count: frameSamples / 2))
        drainWorker(svc)
        XCTAssertEqual(backend.classifyCalls, 1) // unchanged
    }

    // MARK: - Helpers

    /// Drain pending async work synchronously via the worker queue's sync barrier.
    private func drainWorker(_ svc: VADService) {
        svc.waitForPendingWork()
    }
}
