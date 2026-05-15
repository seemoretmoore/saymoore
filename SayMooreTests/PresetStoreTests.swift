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

    // MARK: - Vocabulary (v1.1 Custom Dictionary)

    func testParsesVocabularyFromDisk() throws {
        let url = fileURL()
        try write(#"""
            {"default":"DEF","vocabulary":["FSEventStream","Qwen","AVAudioEngine"]}
            """#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)
        XCTAssertEqual(store.vocabulary(), ["FSEventStream", "Qwen", "AVAudioEngine"])
        XCTAssertNil(store.initialVocabularyWarning)
    }

    func testMissingVocabularyKeyMeansEmpty() throws {
        let url = fileURL()
        try write(#"{"default":"DEF"}"#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)
        XCTAssertEqual(store.vocabulary(), [])
        XCTAssertNil(store.initialVocabularyWarning)
    }

    func testExplicitNullVocabularyTolerated() throws {
        let url = fileURL()
        try write(#"{"default":"DEF","vocabulary":null}"#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)
        XCTAssertEqual(store.vocabulary(), [])
        XCTAssertNil(store.initialVocabularyWarning)
    }

    func testEmptyAndWhitespaceVocabularyEntriesDropSilently() throws {
        let url = fileURL()
        try write(#"""
            {"default":"DEF","vocabulary":["","  ","FSEventStream","\t","Qwen"]}
            """#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)
        XCTAssertEqual(store.vocabulary(), ["FSEventStream", "Qwen"])
        XCTAssertNil(store.initialVocabularyWarning)
    }

    func testFiftyOneEntriesRejectsVocabularyOnly() throws {
        let url = fileURL()
        let entries = (1...51).map { "term\($0)" }
        let json = try JSONSerialization.data(withJSONObject: [
            "default": "DEF",
            "overrides": ["com.a": "OVERRIDE-A"],
            "vocabulary": entries
        ])
        try json.write(to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)
        // Vocabulary cleared, but default + overrides still loaded.
        XCTAssertEqual(store.vocabulary(), [])
        XCTAssertEqual(store.preset(for: "com.a").promptTemplate, "OVERRIDE-A")
        XCTAssertEqual(store.preset(for: nil).promptTemplate, "DEF")
        if case .tooManyVocabEntries(let count) = store.initialVocabularyWarning {
            XCTAssertEqual(count, 51)
        } else {
            XCTFail("expected .tooManyVocabEntries, got \(String(describing: store.initialVocabularyWarning))")
        }
    }

    func testEntryOver64BytesRejectsVocabularyOnly() throws {
        let url = fileURL()
        let big = String(repeating: "x", count: 65)
        let payload: [String: Any] = ["default": "DEF", "vocabulary": ["ok", big]]
        let json = try JSONSerialization.data(withJSONObject: payload)
        try json.write(to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)
        XCTAssertEqual(store.vocabulary(), [])
        XCTAssertEqual(store.preset(for: nil).promptTemplate, "DEF")
        if case .vocabEntryTooLong(let bytes) = store.initialVocabularyWarning {
            XCTAssertEqual(bytes, 65)
        } else {
            XCTFail("expected .vocabEntryTooLong, got \(String(describing: store.initialVocabularyWarning))")
        }
    }

    func testWrappedVocabularyOverCapRejectsVocabularyOnly() throws {
        let url = fileURL()
        // 12 entries × 64 bytes = 768 B raw + wrapper + ", " separators > 512 B cap.
        let entries = (1...12).map { _ in String(repeating: "x", count: 64) }
        let json = try JSONSerialization.data(withJSONObject: ["default": "DEF", "vocabulary": entries])
        try json.write(to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)
        XCTAssertEqual(store.vocabulary(), [])
        if case .vocabularyTooLarge = store.initialVocabularyWarning { } else {
            XCTFail("expected .vocabularyTooLarge, got \(String(describing: store.initialVocabularyWarning))")
        }
    }

    func testFirstViolationWinsCountBeforeEntryLength() throws {
        let url = fileURL()
        // 51 entries AND one is 100 chars — count check fires first.
        var entries = (1...50).map { "t\($0)" }
        entries.append(String(repeating: "y", count: 100))
        let json = try JSONSerialization.data(withJSONObject: ["default": "DEF", "vocabulary": entries])
        try json.write(to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)
        if case .tooManyVocabEntries = store.initialVocabularyWarning { } else {
            XCTFail("expected .tooManyVocabEntries (count check before entry-length check), got \(String(describing: store.initialVocabularyWarning))")
        }
    }

    func testMalformedVocabularyShapeRejectedAsPartialFailure() throws {
        // vocab as a string (not array) — partial failure, rest of file loads.
        let url = fileURL()
        try write(#"""
            {"default":"DEF","overrides":{"com.a":"A"},"vocabulary":"FSEventStream"}
            """#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)
        XCTAssertEqual(store.vocabulary(), [])
        XCTAssertEqual(store.preset(for: "com.a").promptTemplate, "A")
        XCTAssertEqual(store.preset(for: nil).promptTemplate, "DEF")
        XCTAssertEqual(store.initialVocabularyWarning, .vocabularyMalformed)
    }

    func testMalformedVocabularyNumberRejectedAsPartialFailure() throws {
        let url = fileURL()
        try write(#"{"default":"DEF","vocabulary":42}"#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)
        XCTAssertEqual(store.vocabulary(), [])
        XCTAssertEqual(store.preset(for: nil).promptTemplate, "DEF")
        XCTAssertEqual(store.initialVocabularyWarning, .vocabularyMalformed)
    }

    func testMalformedVocabularyMixedElementTypesRejected() throws {
        let url = fileURL()
        try write(#"{"default":"DEF","vocabulary":["FSEventStream",42]}"#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)
        XCTAssertEqual(store.vocabulary(), [])
        XCTAssertEqual(store.initialVocabularyWarning, .vocabularyMalformed)
    }

    func testNullEntriesInVocabularyArrayDropSilently() throws {
        // null entries are tolerated like empty-after-trim entries — consistent
        // with the permissive hand-editing model (accidental commas / nulls).
        let url = fileURL()
        try write(#"{"default":"DEF","vocabulary":["FSEventStream",null,"Qwen",null]}"#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)
        XCTAssertEqual(store.vocabulary(), ["FSEventStream", "Qwen"])
        XCTAssertNil(store.initialVocabularyWarning)
    }

    // MARK: - Reload dedupe + transition

    func testReloadDedupesSameWarningOnRepeatLoads() throws {
        let url = fileURL()
        // Initial: clean. Then write same bad vocab twice. First reload surfaces;
        // second reload of identical content returns nil (dedupe).
        try write(#"{"default":"DEF"}"#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)
        XCTAssertNil(store.initialVocabularyWarning)

        let bad = String(repeating: "x", count: 65)
        let badPayload: [String: Any] = ["default": "DEF", "vocabulary": ["ok", bad]]
        try JSONSerialization.data(withJSONObject: badPayload).write(to: url)

        let first = try store.reload()
        if case .vocabEntryTooLong = first.vocabularyWarning { } else {
            XCTFail("first reload should surface .vocabEntryTooLong, got \(String(describing: first.vocabularyWarning))")
        }
        let second = try store.reload()
        XCTAssertNil(second.vocabularyWarning, "repeat-reload of same warning must be deduped")
    }

    func testReloadSurfacesDifferentWarningAfterPriorOne() throws {
        let url = fileURL()
        try write(#"{"default":"DEF"}"#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)

        // First: too-long entry.
        let bad = String(repeating: "x", count: 65)
        try JSONSerialization.data(withJSONObject: ["default": "DEF", "vocabulary": ["ok", bad]])
            .write(to: url)
        _ = try store.reload()

        // Now switch to too-many entries — different discriminant → re-surfaces.
        let many = (1...51).map { "term\($0)" }
        try JSONSerialization.data(withJSONObject: ["default": "DEF", "vocabulary": many])
            .write(to: url)
        let outcome = try store.reload()
        if case .tooManyVocabEntries = outcome.vocabularyWarning { } else {
            XCTFail("transition to different warning must re-surface, got \(String(describing: outcome.vocabularyWarning))")
        }
    }

    func testReloadDoesNotSurfaceRecoveryFromWarningToClean() throws {
        let url = fileURL()
        try write(#"{"default":"DEF"}"#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)

        // Plant a bad vocab, then fix it.
        let bad = String(repeating: "x", count: 65)
        try JSONSerialization.data(withJSONObject: ["default": "DEF", "vocabulary": ["ok", bad]])
            .write(to: url)
        _ = try store.reload()
        try write(#"{"default":"DEF","vocabulary":["FSEventStream"]}"#, to: url)
        let outcome = try store.reload()
        XCTAssertNil(outcome.vocabularyWarning, "recovery (err→nil) must not post a toast")
        XCTAssertEqual(store.vocabulary(), ["FSEventStream"])
    }

    // MARK: - Vocabulary formatter

    func testVocabularyPromptStringEmpty() {
        XCTAssertNil(PresetStore.vocabularyPromptString([]))
    }

    func testVocabularyPromptStringSingle() {
        XCTAssertEqual(
            PresetStore.vocabularyPromptString(["FSEventStream"]),
            "The following transcript may include these terms: FSEventStream."
        )
    }

    func testVocabularyPromptStringMulti() {
        XCTAssertEqual(
            PresetStore.vocabularyPromptString(["FSEventStream", "Qwen", "AVAudioEngine"]),
            "The following transcript may include these terms: FSEventStream, Qwen, AVAudioEngine."
        )
    }
}
