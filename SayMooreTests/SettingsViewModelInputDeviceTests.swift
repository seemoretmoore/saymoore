import XCTest
import CoreAudio
@testable import SayMoore

@MainActor
final class SettingsViewModelInputDeviceTests: XCTestCase {
    private var tmpDir: URL!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsVMInputDeviceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        if let d = tmpDir { try? FileManager.default.removeItem(at: d) }
        UserDefaults.standard.removeObject(forKey: AudioRecorder.inputDeviceUIDKey)
    }
    private func makeStore() throws -> PresetStore {
        let url = tmpDir.appendingPathComponent("presets.json")
        try #"{"default":"X{{transcript}}"}"#.data(using: .utf8)!.write(to: url, options: .atomic)
        return PresetStore(fileURL: url, materializeIfMissing: false)
    }
    private func dev(_ uid: String, _ id: AudioDeviceID) -> AudioInputDevice {
        AudioInputDevice(id: id, uid: uid, name: uid, transportType: 0, nominalSampleRate: 48_000)
    }

    func test_availableInputDevices_comeFromEnumerator() throws {
        let fake = FakeInputDeviceEnumerator(devices: [dev("usb-1", 7), dev("built-in", 3)])
        let vm = SettingsViewModel(presets: try makeStore(), enumerator: fake)
        XCTAssertEqual(vm.availableInputDevices.map(\.uid), ["usb-1", "built-in"])
    }

    func test_selectingDevice_persistsUID() throws {
        let fake = FakeInputDeviceEnumerator(devices: [dev("usb-1", 7)])
        let vm = SettingsViewModel(presets: try makeStore(), enumerator: fake)
        vm.inputDeviceUID = "usb-1"
        XCTAssertEqual(UserDefaults.standard.string(forKey: AudioRecorder.inputDeviceUIDKey), "usb-1")
    }

    func test_selectingSystemDefault_clearsUID() throws {
        UserDefaults.standard.set("usb-1", forKey: AudioRecorder.inputDeviceUIDKey)
        let vm = SettingsViewModel(presets: try makeStore(),
                                   enumerator: FakeInputDeviceEnumerator(devices: []))
        XCTAssertEqual(vm.inputDeviceUID, "usb-1")  // hydrated from defaults
        vm.inputDeviceUID = nil
        XCTAssertNil(UserDefaults.standard.string(forKey: AudioRecorder.inputDeviceUIDKey))
    }
}
