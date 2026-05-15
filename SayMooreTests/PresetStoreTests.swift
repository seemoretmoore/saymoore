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
        let data = try XCTUnwrap(json.data(using: .utf8))
        try data.write(to: url, options: .atomic)
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

    func testIgnoresUnknownKeysForForwardCompat() throws {
        let url = fileURL()
        try write(#"{"default":"X{{transcript}}Y","futureKey":42}"#, to: url)

        let store = PresetStore(fileURL: url, materializeIfMissing: false)

        XCTAssertEqual(store.defaultPreset().promptTemplate, "X{{transcript}}Y")
    }

    // MARK: - Overrides (Slice 4)

    func testParsesOverridesAndResolvesByBundleID() throws {
        let url = fileURL()
        try write(#"""
            {"default":"DEF","overrides":{"com.tinyspeck.slackmacgap":"SLACK","com.apple.mail":"MAIL"}}
            """#, to: url)

        let store = PresetStore(fileURL: url, materializeIfMissing: false)

        XCTAssertEqual(store.preset(for: "com.tinyspeck.slackmacgap").promptTemplate, "SLACK")
        XCTAssertEqual(store.preset(for: "com.tinyspeck.slackmacgap").name, "com.tinyspeck.slackmacgap")
        XCTAssertEqual(store.preset(for: "com.apple.mail").promptTemplate, "MAIL")
        XCTAssertEqual(store.preset(for: "com.unknown.app").promptTemplate, "DEF")
        XCTAssertEqual(store.preset(for: nil).promptTemplate, "DEF")
    }

    func testSkipsEmptyOverrideTemplates() throws {
        let url = fileURL()
        try write(#"""
            {"default":"DEF","overrides":{"com.a":"","com.b":"REAL"}}
            """#, to: url)

        let store = PresetStore(fileURL: url, materializeIfMissing: false)

        XCTAssertEqual(store.preset(for: "com.a").promptTemplate, "DEF") // empty skipped
        XCTAssertEqual(store.preset(for: "com.b").promptTemplate, "REAL")
    }

    func testSkipsNonStringOverrideValues() throws {
        let url = fileURL()
        try write(#"""
            {"default":"DEF","overrides":{"com.a":42,"com.b":"REAL"}}
            """#, to: url)

        let store = PresetStore(fileURL: url, materializeIfMissing: false)

        XCTAssertEqual(store.preset(for: "com.a").promptTemplate, "DEF")
        XCTAssertEqual(store.preset(for: "com.b").promptTemplate, "REAL")
    }

    func testReloadUpdatesOverrides() throws {
        let url = fileURL()
        try write(#"{"default":"D1","overrides":{"com.a":"V1"}}"#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)
        XCTAssertEqual(store.preset(for: "com.a").promptTemplate, "V1")

        try write(#"{"default":"D2","overrides":{"com.a":"V2","com.b":"VB"}}"#, to: url)
        try store.reload()

        XCTAssertEqual(store.preset(for: "com.a").promptTemplate, "V2")
        XCTAssertEqual(store.preset(for: "com.b").promptTemplate, "VB")
        XCTAssertEqual(store.defaultPreset().promptTemplate, "D2")
    }

    func testReloadClearsRemovedOverrides() throws {
        let url = fileURL()
        try write(#"{"default":"D","overrides":{"com.a":"V"}}"#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)
        XCTAssertEqual(store.preset(for: "com.a").promptTemplate, "V")

        try write(#"{"default":"D"}"#, to: url)
        try store.reload()

        XCTAssertEqual(store.preset(for: "com.a").promptTemplate, "D") // override gone, falls back
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

    // MARK: - Bundle-ID-less resolution falls through to default

    func testPresetForBundleIDReturnsDefault() throws {
        let url = fileURL()
        try write(#"{"default":"v"}"#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)
        XCTAssertEqual(store.preset(for: "com.apple.Slack").promptTemplate, "v")
        XCTAssertEqual(store.preset(for: nil).promptTemplate, "v")
    }

    // MARK: - ensureMaterialized (A4)

    func testEnsureMaterializedRecreatesDeletedFile() throws {
        let url = fileURL()
        let store = PresetStore(fileURL: url, materializeIfMissing: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        try FileManager.default.removeItem(at: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        store.ensureMaterialized()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testEnsureMaterializedIsIdempotent() throws {
        let url = fileURL()
        try write(#"{"default":"CUSTOM"}"#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)

        store.ensureMaterialized()
        store.ensureMaterialized()

        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["default"] as? String, "CUSTOM")
    }

    // MARK: - Bounds (A2)

    func testReloadRejectsOversizeFile() throws {
        let url = fileURL()
        try write(#"{"default":"v"}"#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)

        // Build a payload that's a valid JSON shape but larger than the cap.
        let padding = String(repeating: "x", count: PresetStore.maxFileBytes + 100)
        try write("{\"default\":\"v\",\"_pad\":\"\(padding)\"}", to: url)

        do {
            try store.reload()
            XCTFail("expected fileTooLarge")
        } catch let e as PresetStoreError {
            if case .fileTooLarge = e {} else { XCTFail("wrong error: \(e)") }
        }
        // Last-good retained.
        XCTAssertEqual(store.defaultPreset().promptTemplate, "v")
    }

    func testReloadRejectsTooManyOverrides() throws {
        let url = fileURL()
        try write(#"{"default":"v"}"#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)

        var overrides: [String: String] = [:]
        for i in 0...(PresetStore.maxOverridesCount) {
            overrides["bundle.id.\(i)"] = "t"
        }
        let data = try JSONSerialization.data(withJSONObject: ["default": "new", "overrides": overrides])
        try data.write(to: url, options: .atomic)

        do {
            try store.reload()
            XCTFail("expected tooManyOverrides")
        } catch let e as PresetStoreError {
            if case .tooManyOverrides = e {} else { XCTFail("wrong error: \(e)") }
        }
        XCTAssertEqual(store.defaultPreset().promptTemplate, "v")
    }

    func testReloadRejectsOversizeTemplate() throws {
        let url = fileURL()
        try write(#"{"default":"v"}"#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)

        let huge = String(repeating: "x", count: PresetStore.maxTemplateBytes + 1)
        let data = try JSONSerialization.data(withJSONObject: ["default": "new", "overrides": ["com.example": huge]])
        try data.write(to: url, options: .atomic)

        do {
            try store.reload()
            XCTFail("expected templateTooLong")
        } catch let e as PresetStoreError {
            if case .templateTooLong = e {} else { XCTFail("wrong error: \(e)") }
        }
        XCTAssertEqual(store.defaultPreset().promptTemplate, "v")
    }

    func testReloadRejectsNonRegularFile() throws {
        // Replace presets.json with a directory of the same name.
        // (Symlink-to-/dev/null doesn't trip isRegularFile on this system —
        // a directory is the most portable non-regular substitute.)
        let url = fileURL()
        try write(#"{"default":"v"}"#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)

        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)

        do {
            try store.reload()
            XCTFail("expected notRegularFile")
        } catch let e as PresetStoreError {
            if case .notRegularFile = e {} else { XCTFail("wrong error: \(e)") }
        }
        XCTAssertEqual(store.defaultPreset().promptTemplate, "v")
    }

    // MARK: - Drift: presets.example.json default must match PresetStore.defaultPromptTemplate

    func testPresetsExampleJsonDefaultMatchesHardcodedTemplate() throws {
        // Resource ships in the production app bundle; load from there rather than the test bundle.
        let resourceURL = try XCTUnwrap(
            Bundle(for: PresetStore.self).url(forResource: "presets.example", withExtension: "json"),
            "presets.example.json not found in SayMoore app bundle"
        )
        let data = try Data(contentsOf: resourceURL)
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "presets.example.json is not a JSON object"
        )
        let bundledDefault = try XCTUnwrap(
            obj["default"] as? String,
            "presets.example.json missing 'default' key"
        )
        XCTAssertEqual(
            bundledDefault,
            PresetStore.defaultPromptTemplate,
            "presets.example.json 'default' has drifted from PresetStore.defaultPromptTemplate — update both together"
        )
    }
}
