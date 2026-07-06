import XCTest
import CoreAudio
@testable import SayMoore

@MainActor
final class AudioRecorderDevicePinTests: XCTestCase {
    private func dev(_ uid: String, _ id: AudioDeviceID) -> AudioInputDevice {
        AudioInputDevice(id: id, uid: uid, name: uid, transportType: 0, nominalSampleRate: 48_000)
    }

    func test_resolvePinnedDeviceID_resolvesViaEnumerator() {
        let fake = FakeInputDeviceEnumerator(devices: [dev("usb-1", 7), dev("built-in", 3)])
        let rec = AudioRecorder(deviceEnumerator: fake, pinnedDeviceUIDProvider: { "usb-1" })
        XCTAssertEqual(rec.resolvePinnedDeviceID(), 7)
    }

    func test_resolvePinnedDeviceID_nilWhenNoUIDPinned() {
        let fake = FakeInputDeviceEnumerator(devices: [dev("usb-1", 7)])
        let rec = AudioRecorder(deviceEnumerator: fake, pinnedDeviceUIDProvider: { nil })
        XCTAssertNil(rec.resolvePinnedDeviceID(), "no pin → follow system default")
    }

    func test_resolvePinnedDeviceID_nilWhenPinnedUIDAbsent() {
        // Pinned USB mic was unplugged: UID no longer enumerates → fall back.
        let fake = FakeInputDeviceEnumerator(devices: [dev("built-in", 3)])
        let rec = AudioRecorder(deviceEnumerator: fake, pinnedDeviceUIDProvider: { "usb-1" })
        XCTAssertNil(rec.resolvePinnedDeviceID())
    }

    func test_emptyStringUID_treatedAsSystemDefault() {
        let fake = FakeInputDeviceEnumerator(devices: [dev("usb-1", 7)])
        let rec = AudioRecorder(deviceEnumerator: fake, pinnedDeviceUIDProvider: { "" })
        XCTAssertNil(rec.resolvePinnedDeviceID())
    }
}
