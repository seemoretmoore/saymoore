@testable import SayMoore
import CoreAudio

final class FakeInputDeviceEnumerator: AudioInputDeviceEnumerating, @unchecked Sendable {
    let devices: [AudioInputDevice]
    let defaultDevice: AudioInputDevice?
    init(devices: [AudioInputDevice], defaultDevice: AudioInputDevice? = nil) {
        self.devices = devices
        self.defaultDevice = defaultDevice
    }
    func inputDevices() -> [AudioInputDevice] { devices }
    func deviceID(forUID uid: String) -> AudioDeviceID? { devices.first { $0.uid == uid }?.id }
    func defaultInputDevice() -> AudioInputDevice? { defaultDevice }
}
