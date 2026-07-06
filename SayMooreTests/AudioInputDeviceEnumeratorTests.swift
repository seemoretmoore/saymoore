import XCTest
import CoreAudio
@testable import SayMoore

final class AudioInputDeviceEnumeratorTests: XCTestCase {
    // The real CoreAudio enumerator must never crash and must return a
    // well-formed array (possibly empty on a headless CI host).
    func test_realEnumerator_inputDevices_isWellFormed_andDoesNotCrash() {
        let e = CoreAudioInputDeviceEnumerator()
        let devices = e.inputDevices()
        for d in devices {
            XCTAssertFalse(d.uid.isEmpty, "every enumerated device must carry a UID")
            XCTAssertGreaterThan(d.id, 0)
        }
        // UIDs are unique within a single enumeration.
        XCTAssertEqual(Set(devices.map(\.uid)).count, devices.count)
    }

    // A UID that cannot exist resolves to nil rather than a bogus ID.
    func test_realEnumerator_bogusUID_resolvesToNil() {
        let e = CoreAudioInputDeviceEnumerator()
        XCTAssertNil(e.deviceID(forUID: "com.saymoore.NO_SUCH_DEVICE_\(UUID().uuidString)"))
    }

    // The fake seam round-trips UID → id for downstream unit tests.
    func test_fake_resolvesKnownUID() {
        let dev = AudioInputDevice(id: 42, uid: "usb-mic-1", name: "USB Mic",
                                   transportType: 0, nominalSampleRate: 48_000)
        let e = FakeInputDeviceEnumerator(devices: [dev])
        XCTAssertEqual(e.deviceID(forUID: "usb-mic-1"), 42)
        XCTAssertNil(e.deviceID(forUID: "absent"))
    }
}
