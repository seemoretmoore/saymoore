import XCTest
import AVFoundation
@testable import SayMoore

@MainActor
final class AudioRecorderConfigChangeTests: XCTestCase {
    func test_configurationChange_whileRecording_invokesCallback_andStopsEngine() async throws {
        let rec = AudioRecorder()
        var fired = false
        rec.onDeviceChange = { fired = true }
        try? rec.start()
        guard rec.isRecording else { throw XCTSkip("no input device on test host") }
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: rec.engineForObserverTesting
        )
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(fired)
        XCTAssertFalse(rec.isRecording)
    }
}
