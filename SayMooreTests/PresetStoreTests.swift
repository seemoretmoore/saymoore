import XCTest
@testable import SayMoore

final class PresetStoreTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PresetStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        tmpDir = base
    }

    override func tearDownWithError() throws {
        if let dir = tmpDir { try? FileManager.default.removeItem(at: dir) }
    }

    private func fileURL() -> URL {
        tmpDir.appendingPathComponent("presets.json", isDirectory: false)
    }

    private func write(_ json: String, to url: URL) throws {
        try json.data(using: .utf8)!.write(to: url, options: .atomic)
    }

    // MARK: - Materialization

    func testMaterializesFileOnFirstLaunchWhenAbsent() throws {
        let url = fileURL()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        _ = PresetStore(fileURL: url, materializeIfMissing: true)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["default"] as? String, PresetStore.defaultPromptTemplate)
    }

    func testDoesNotOverwriteExistingFile() throws {
        let url = fileURL()
        try write(#"{"default":"CUSTOM"}"#, to: url)

        _ = PresetStore(fileURL: url, materializeIfMissing: true)

        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["default"] as? String, "CUSTOM")
    }

    // MARK: - Load

    func testLoadsCustomDefaultFromDisk() throws {
        let url = fileURL()
        try write(#"{"default":"hello {{transcript}}"}"#, to: url)

        let store = PresetStore(fileURL: url, materializeIfMissing: false)

        XCTAssertEqual(store.defaultPreset().promptTemplate, "hello {{transcript}}")
    }

    func testFallsBackToHardcodedBaselineWhenFileMissingAndNoMaterialization() {
        let url = fileURL() // file does not exist
        let store = PresetStore(fileURL: url, materializeIfMissing: false)
        XCTAssertEqual(store.defaultPreset().promptTemplate, PresetStore.defaultPromptTemplate)
    }

    func testIgnoresUnknownKeysForSlice4ForwardCompat() throws {
        let url = fileURL()
        try write(#"""
            {"default":"X{{transcript}}Y","overrides":{"com.tinyspeck.slackmacgap":"slack tone"}}
            """#, to: url)

        let store = PresetStore(fileURL: url, materializeIfMissing: false)

        XCTAssertEqual(store.defaultPreset().promptTemplate, "X{{transcript}}Y")
    }

    // MARK: - Reload

    func testReloadPicksUpEditedFile() throws {
        let url = fileURL()
        try write(#"{"default":"first"}"#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)
        XCTAssertEqual(store.defaultPreset().promptTemplate, "first")

        try write(#"{"default":"second"}"#, to: url)
        try store.reload()

        XCTAssertEqual(store.defaultPreset().promptTemplate, "second")
    }

    func testReloadRetainsPriorPresetOnMalformedJSON() throws {
        let url = fileURL()
        try write(#"{"default":"good"}"#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)

        try write("not json", to: url)

        XCTAssertThrowsError(try store.reload()) { err in
            guard case PresetStoreError.malformedJSON = err else {
                return XCTFail("expected malformedJSON, got \(err)")
            }
        }
        XCTAssertEqual(store.defaultPreset().promptTemplate, "good")
    }

    func testReloadRetainsPriorPresetWhenDefaultKeyMissing() throws {
        let url = fileURL()
        try write(#"{"default":"good"}"#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)

        try write(#"{"overrides":{}}"#, to: url)

        XCTAssertThrowsError(try store.reload()) { err in
            guard case PresetStoreError.missingDefaultKey = err else {
                return XCTFail("expected missingDefaultKey, got \(err)")
            }
        }
        XCTAssertEqual(store.defaultPreset().promptTemplate, "good")
    }

    func testReloadFailsCleanlyWhenFileDeleted() throws {
        let url = fileURL()
        try write(#"{"default":"good"}"#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)

        try FileManager.default.removeItem(at: url)

        XCTAssertThrowsError(try store.reload()) { err in
            guard case PresetStoreError.fileUnreadable = err else {
                return XCTFail("expected fileUnreadable, got \(err)")
            }
        }
        XCTAssertEqual(store.defaultPreset().promptTemplate, "good")
    }

    // MARK: - bundleID is currently ignored (Slice 4 will change this)

    func testPresetForBundleIDReturnsDefault() throws {
        let url = fileURL()
        try write(#"{"default":"v"}"#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)
        XCTAssertEqual(store.preset(for: "com.apple.Slack").promptTemplate, "v")
        XCTAssertEqual(store.preset(for: nil).promptTemplate, "v")
    }
}
