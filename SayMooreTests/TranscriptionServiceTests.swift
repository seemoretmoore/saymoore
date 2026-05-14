import XCTest
@testable import SayMoore

// D2: lifecycle stress — exercises the NSLock/wasFreed deinit pattern without requiring a real whisper ctx.
// The #else branch of WhisperTranscriptionService (no whisper import) throws modelMissing immediately,
// which means the serial queue's work completes before or after deinit; the lock pattern must not crash.
final class TranscriptionServiceLifecycleTests: XCTestCase {

    // D2: Create service, fire a transcribe Task, drop the reference immediately, await — no crash within 2s.
    func testDeinitWhileTranscribeInFlightDoesNotCrash() async {
        var svc: WhisperTranscriptionService? = WhisperTranscriptionService(modelPath: "/nonexistent/model.bin")
        let samples = [Float](repeating: 0, count: 16_000) // 1s of silence at 16kHz

        let task = Task { [weak svc] in
            // Swallow any error — we only care about no crash / no hang.
            // Use weak capture so a nil-ing between Task creation and execution doesn't crash.
            guard let svc else { return }
            _ = try? await svc.transcribe(samples: samples, sampleRate: 16_000)
        }

        // Drop reference to trigger deinit (may race with the in-flight task).
        svc = nil

        // Must complete within 2s — deadlock or use-after-free would cause hang or crash.
        let completed = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await task.value
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return false
            }
            let result = await group.next()!
            group.cancelAll()
            return result
        }
        XCTAssertTrue(completed, "transcribe task did not complete within 2s — possible deadlock")
    }
}
