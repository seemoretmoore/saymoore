import XCTest
import AVFoundation
@testable import SayMoore

@MainActor
final class MicrophonePermissionMonitorTests: XCTestCase {
    func test_emitsRevokedEvent_whenStatusFlipsFromAuthorizedToDenied() async {
        var statuses: [AVAuthorizationStatus] = [.authorized, .authorized, .denied]
        var fired = false
        let mon = MicrophonePermissionMonitor(
            poll: .milliseconds(10),
            statusProvider: { statuses.isEmpty ? .denied : statuses.removeFirst() },
            onRevoked: { fired = true }
        )
        mon.start()
        try? await Task.sleep(for: .milliseconds(80))
        mon.stop()
        XCTAssertTrue(fired)
    }
}
