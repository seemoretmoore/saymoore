import XCTest
import AVFoundation
@testable import SayMoore

@MainActor
final class AudioRecorderConfigChangeTests: XCTestCase {
    // A single mid-recording configuration change (e.g. AirPods being switched
    // into SCO mic mode the instant we start) should re-route the engine onto
    // the current input and KEEP recording — not abort.
    func test_configurationChange_whileRecording_reroutes_andKeepsRecording() async throws {
        let rec = AudioRecorder()
        var aborted = false
        rec.onDeviceChange = { aborted = true }
        try? rec.start()
        guard rec.isRecording else { throw XCTSkip("no input device on test host") }
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: rec.engineForObserverTesting
        )
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(aborted, "a single device change should re-route, not abort")
        XCTAssertTrue(rec.isRecording, "recording should survive a device change")
        _ = try? rec.stop()
    }

    // A sustained storm of configuration changes (a genuinely flapping device,
    // spaced beyond the settle window so each one counts) must eventually fall
    // back to the original abort behavior rather than re-route forever.
    func test_configurationChange_storm_exceedingCap_abortsRecording() async throws {
        let rec = AudioRecorder()
        var aborted = false
        rec.onDeviceChange = { aborted = true }
        try? rec.start()
        guard rec.isRecording else { throw XCTSkip("no input device on test host") }
        // maxReroutesPerSession == 3; the 4th change tips over the cap. Space the
        // posts past the 500ms settle window so they aren't coalesced away.
        for _ in 0..<4 {
            NotificationCenter.default.post(
                name: .AVAudioEngineConfigurationChange,
                object: rec.engineForObserverTesting
            )
            try? await Task.sleep(for: .milliseconds(600))
        }
        XCTAssertTrue(aborted, "a sustained device-change storm should fall back to abort")
        XCTAssertFalse(rec.isRecording)
    }
}
