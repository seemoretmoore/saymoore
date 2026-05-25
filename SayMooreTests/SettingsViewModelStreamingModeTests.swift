import XCTest
@testable import SayMoore

@MainActor
final class SettingsViewModelStreamingModeTests: XCTestCase {
    override func setUp() async throws {
        UserDefaults.standard.removeObject(forKey: StreamingMode.userDefaultsKey)
    }
    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: StreamingMode.userDefaultsKey)
    }

    private func makeStore() throws -> PresetStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("p-\(UUID()).json")
        return PresetStore(fileURL: url, materializeIfMissing: false)
    }

    func testDefaultsToBalancedWhenUnset() throws {
        let vm = SettingsViewModel(presets: try makeStore())
        XCTAssertEqual(vm.streamingMode, .balanced)
    }

    func testSettingPersistsToUserDefaults() throws {
        let vm = SettingsViewModel(presets: try makeStore())
        vm.streamingMode = .responsive
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: StreamingMode.userDefaultsKey),
            "responsive"
        )
    }

    func testReadsExistingUserDefaultsValue() throws {
        UserDefaults.standard.set("off", forKey: StreamingMode.userDefaultsKey)
        let vm = SettingsViewModel(presets: try makeStore())
        XCTAssertEqual(vm.streamingMode, .off)
    }

    func testInvalidUserDefaultsValueFallsBackToDefault() throws {
        UserDefaults.standard.set("bogus-value", forKey: StreamingMode.userDefaultsKey)
        let vm = SettingsViewModel(presets: try makeStore())
        XCTAssertEqual(vm.streamingMode, .balanced)
    }
}
