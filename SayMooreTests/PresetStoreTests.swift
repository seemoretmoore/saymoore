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

    private static let sampleVocabJSON = #"""
        {"default":"DEF","vocabulary":[
            {"phonetic":"FS event stream","canonical":"FSEventStream"},
            {"phonetic":"Quinn","canonical":"Qwen"},
            {"phonetic":"AV audio engine","canonical":"AVAudioEngine"}
        ]}
        """#

    private static let sampleVocab: [VocabEntry] = [
        VocabEntry(phonetic: "FS event stream", canonical: "FSEventStream"),
        VocabEntry(phonetic: "Quinn", canonical: "Qwen"),
        VocabEntry(phonetic: "AV audio engine", canonical: "AVAudioEngine"),
    ]

    func testParsesVocabularyFromDisk() throws {
        let url = fileURL()
        try write(Self.sampleVocabJSON, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)
        XCTAssertEqual(store.vocabulary(), Self.sampleVocab)
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

    private func entriesObject(_ pairs: [(String, String)]) -> [[String: Any]] {
        pairs.map { ["phonetic": $0.0, "canonical": $0.1] }
    }

    func testFiftyOneEntriesRejectsVocabularyOnly() throws {
        let url = fileURL()
        let pairs = (1...51).map { ("p\($0)", "c\($0)") }
        let json = try JSONSerialization.data(withJSONObject: [
            "default": "DEF",
            "overrides": ["com.a": "OVERRIDE-A"],
            "vocabulary": entriesObject(pairs)
        ])
        try json.write(to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)
        XCTAssertEqual(store.vocabulary(), [])
        XCTAssertEqual(store.preset(for: "com.a").promptTemplate, "OVERRIDE-A")
        XCTAssertEqual(store.preset(for: nil).promptTemplate, "DEF")
        if case .tooManyVocabEntries(let count) = store.initialVocabularyWarning {
            XCTAssertEqual(count, 51)
        } else {
            XCTFail("expected .tooManyVocabEntries, got \(String(describing: store.initialVocabularyWarning))")
        }
    }

    func testEntryPhoneticOver64BytesRejectsVocabularyOnly() throws {
        let url = fileURL()
        let big = String(repeating: "x", count: 65)
        let payload: [String: Any] = [
            "default": "DEF",
            "vocabulary": entriesObject([("ok", "Ok"), (big, "Big")])
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)
        XCTAssertEqual(store.vocabulary(), [])
        if case .vocabEntryTooLong(let bytes) = store.initialVocabularyWarning {
            XCTAssertEqual(bytes, 65)
        } else {
            XCTFail("expected .vocabEntryTooLong, got \(String(describing: store.initialVocabularyWarning))")
        }
    }

    func testEntryCanonicalOver64BytesRejectsVocabularyOnly() throws {
        let url = fileURL()
        let big = String(repeating: "x", count: 65)
        let payload: [String: Any] = [
            "default": "DEF",
            "vocabulary": entriesObject([("short", big)])
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)
        XCTAssertEqual(store.vocabulary(), [])
        if case .vocabEntryTooLong(let bytes) = store.initialVocabularyWarning {
            XCTAssertEqual(bytes, 65)
        } else {
            XCTFail("expected .vocabEntryTooLong, got \(String(describing: store.initialVocabularyWarning))")
        }
    }

    func testTotalBytesOverCapRejectsVocabularyOnly() throws {
        let url = fileURL()
        // 5 entries × (60 + 60) bytes phonetic+canonical = 600 B billed > 512 B cap.
        let big = String(repeating: "x", count: 60)
        let pairs = (1...5).map { _ in (big, big) }
        let json = try JSONSerialization.data(withJSONObject: [
            "default": "DEF",
            "vocabulary": entriesObject(pairs)
        ])
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
        var pairs = (1...50).map { ("p\($0)", "c\($0)") }
        pairs.append((String(repeating: "y", count: 100), "ok"))
        let json = try JSONSerialization.data(withJSONObject: [
            "default": "DEF",
            "vocabulary": entriesObject(pairs)
        ])
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

    func testMalformedVocabularyBareStringEntriesRejected() throws {
        // v1.1.0 schema was bare strings; v1.1.1 requires pair-objects.
        let url = fileURL()
        try write(#"{"default":"DEF","vocabulary":["FSEventStream","Qwen"]}"#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)
        XCTAssertEqual(store.vocabulary(), [])
        XCTAssertEqual(store.initialVocabularyWarning, .vocabularyMalformed)
    }

    func testMalformedVocabularyMissingCanonicalRejected() throws {
        let url = fileURL()
        try write(#"{"default":"DEF","vocabulary":[{"phonetic":"Quinn"}]}"#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)
        XCTAssertEqual(store.vocabulary(), [])
        XCTAssertEqual(store.initialVocabularyWarning, .vocabularyMalformed)
    }

    func testMalformedVocabularyEmptyPhoneticRejected() throws {
        let url = fileURL()
        try write(#"{"default":"DEF","vocabulary":[{"phonetic":"","canonical":"Qwen"}]}"#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)
        XCTAssertEqual(store.vocabulary(), [])
        XCTAssertEqual(store.initialVocabularyWarning, .vocabularyMalformed)
    }

    func testEntryBothFieldsEmptyAfterTrimDropsSilently() throws {
        let url = fileURL()
        // Both empty-after-trim → drop (permissive). One good entry remains.
        try write(#"""
            {"default":"DEF","vocabulary":[
                {"phonetic":"   ","canonical":""},
                {"phonetic":"Quinn","canonical":"Qwen"}
            ]}
            """#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)
        XCTAssertEqual(store.vocabulary(), [VocabEntry(phonetic: "Quinn", canonical: "Qwen")])
        XCTAssertNil(store.initialVocabularyWarning)
    }

    func testNullEntriesInVocabularyArrayDropSilently() throws {
        let url = fileURL()
        try write(#"""
            {"default":"DEF","vocabulary":[
                {"phonetic":"Quinn","canonical":"Qwen"},
                null,
                {"phonetic":"FS event stream","canonical":"FSEventStream"},
                null
            ]}
            """#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)
        XCTAssertEqual(store.vocabulary(), [
            VocabEntry(phonetic: "Quinn", canonical: "Qwen"),
            VocabEntry(phonetic: "FS event stream", canonical: "FSEventStream"),
        ])
        XCTAssertNil(store.initialVocabularyWarning)
    }

    // MARK: - Reload dedupe + transition

    private func badPairEntryPayload() throws -> Data {
        let big = String(repeating: "x", count: 65)
        return try JSONSerialization.data(withJSONObject: [
            "default": "DEF",
            "vocabulary": [["phonetic": big, "canonical": "ok"]]
        ])
    }

    func testReloadDedupesSameWarningOnRepeatLoads() throws {
        let url = fileURL()
        try write(#"{"default":"DEF"}"#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)
        XCTAssertNil(store.initialVocabularyWarning)

        try badPairEntryPayload().write(to: url)
        let first = try store.reload()
        if case .vocabEntryTooLong = first.vocabularyWarning { } else {
            XCTFail("first reload should surface .vocabEntryTooLong, got \(String(describing: first.vocabularyWarning))")
        }
        let second = try store.reload()
        XCTAssertNil(second.vocabularyWarning, "repeat-reload of same warning must be deduped")
    }

    func testReloadDedupesSameDiscriminantDifferentValue() throws {
        // bug_005: dedupe must compare discriminants, not full Equatable.
        // Banner copy in AppDelegate ignores the associated value, so
        // .vocabEntryTooLong(bytes: 65) and .vocabEntryTooLong(bytes: 70)
        // render the same user-facing string — surfacing both is spam.
        let url = fileURL()
        try write(#"{"default":"DEF"}"#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)

        // First reload: 65-byte phonetic → .vocabEntryTooLong(bytes: 65).
        let bytes65 = String(repeating: "x", count: 65)
        try JSONSerialization.data(withJSONObject: [
            "default": "DEF",
            "vocabulary": [["phonetic": bytes65, "canonical": "ok"]]
        ]).write(to: url)
        let first = try store.reload()
        if case .vocabEntryTooLong = first.vocabularyWarning { } else {
            XCTFail("first reload should surface .vocabEntryTooLong, got \(String(describing: first.vocabularyWarning))")
        }

        // Second reload: 70-byte phonetic → .vocabEntryTooLong(bytes: 70).
        // Same discriminant, different associated value → must dedupe.
        let bytes70 = String(repeating: "x", count: 70)
        try JSONSerialization.data(withJSONObject: [
            "default": "DEF",
            "vocabulary": [["phonetic": bytes70, "canonical": "ok"]]
        ]).write(to: url)
        let second = try store.reload()
        XCTAssertNil(
            second.vocabularyWarning,
            "same-discriminant repeats with different associated values must dedupe (banner text is identical)"
        )
    }

    func testReloadSurfacesDifferentWarningAfterPriorOne() throws {
        let url = fileURL()
        try write(#"{"default":"DEF"}"#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)

        try badPairEntryPayload().write(to: url)
        _ = try store.reload()

        let many = (1...51).map { ["phonetic": "p\($0)", "canonical": "c\($0)"] }
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

        try badPairEntryPayload().write(to: url)
        _ = try store.reload()

        try write(#"""
            {"default":"DEF","vocabulary":[{"phonetic":"Quinn","canonical":"Qwen"}]}
            """#, to: url)
        let outcome = try store.reload()
        XCTAssertNil(outcome.vocabularyWarning, "recovery (err→nil) must not post a toast")
        XCTAssertEqual(store.vocabulary(), [VocabEntry(phonetic: "Quinn", canonical: "Qwen")])
    }

    // MARK: - Byte-cap accounting

    func testVocabularyBilledBytesEmpty() {
        XCTAssertEqual(PresetStore.vocabularyBilledBytes([]), 0)
    }

    func testVocabularyBilledBytesSumsPhoneticAndCanonical() {
        // "AB" (2) + "CDE" (3) = 5
        let vocab = [VocabEntry(phonetic: "AB", canonical: "CDE")]
        XCTAssertEqual(PresetStore.vocabularyBilledBytes(vocab), 5)
    }

    func testVocabularyBilledBytesSumsAcrossEntries() {
        let vocab = [
            VocabEntry(phonetic: "Quinn", canonical: "Qwen"),       // 5 + 4 = 9
            VocabEntry(phonetic: "AV audio engine", canonical: "AVAudioEngine"), // 15 + 13 = 28
        ]
        XCTAssertEqual(PresetStore.vocabularyBilledBytes(vocab), 9 + 28)
    }

    // MARK: - Schema versioning + upgrade (v1.1)

    func testDiskVersionZeroWhenFieldMissing() throws {
        let url = fileURL()
        try write(#"{"default":"X{{transcript}}"}"#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)
        XCTAssertEqual(store.diskSchemaVersion(), 0)
    }

    func testDiskVersionParsedFromField() throws {
        let url = fileURL()
        try write(#"{"$schemaVersion":7,"default":"X{{transcript}}"}"#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)
        XCTAssertEqual(store.diskSchemaVersion(), 7)
    }

    func testDiskVersionClampsNegativeToZero() throws {
        let url = fileURL()
        try write(#"{"$schemaVersion":-3,"default":"X{{transcript}}"}"#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)
        XCTAssertEqual(store.diskSchemaVersion(), 0)
    }

    func testUpgradeAvailableWhenDiskBehindBundled() throws {
        let url = fileURL()
        try write(#"{"default":"OLD {{transcript}}"}"#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)
        if case let .upgradeAvailable(disk, bundled) = store.upgradeStatus() {
            XCTAssertEqual(disk, 0)
            XCTAssertEqual(bundled, PresetStore.bundledSchemaVersion)
        } else {
            XCTFail("expected .upgradeAvailable")
        }
    }

    func testUpToDateWhenDiskMatchesBundled() throws {
        let url = fileURL()
        let v = PresetStore.bundledSchemaVersion
        try write(#"{"$schemaVersion":\#(v),"default":"X{{transcript}}"}"#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)
        XCTAssertEqual(store.upgradeStatus(), .upToDate)
    }

    func testUpToDateWhenDiskAheadOfBundled() throws {
        let url = fileURL()
        let ahead = PresetStore.bundledSchemaVersion + 5
        try write(#"{"$schemaVersion":\#(ahead),"default":"X{{transcript}}"}"#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)
        XCTAssertEqual(store.upgradeStatus(), .upToDate)
    }

    func testMaterializeCopiesBundledIncludingSchemaVersion() throws {
        // First-launch path: materialize copies the bundled file verbatim, so
        // a freshly-installed user starts at the current schema version and
        // does NOT trigger an upgrade prompt.
        let url = fileURL()
        let store = PresetStore(fileURL: url, materializeIfMissing: true)
        XCTAssertEqual(store.upgradeStatus(), .upToDate, "first-launch users must not see an upgrade prompt")
    }

    func testDismissBumpsVersionWithoutTouchingPrompts() throws {
        let url = fileURL()
        try write(#"{"default":"MY CUSTOM {{transcript}}","overrides":{"com.x.app":"Y {{transcript}}"}}"#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)
        try store.applyUpgrade(.dismiss)

        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(obj?["$schemaVersion"] as? Int, PresetStore.bundledSchemaVersion)
        XCTAssertEqual(obj?["default"] as? String, "MY CUSTOM {{transcript}}")
        let overrides = obj?["overrides"] as? [String: Any]
        XCTAssertEqual(overrides?["com.x.app"] as? String, "Y {{transcript}}")
    }

    func testMergeReplacesDefaultPreservesOverridesAndVocabulary() throws {
        // Simulates a v1.0.1 user with custom override + vocab. Merge should
        // adopt the bundled default but leave their additions intact.
        let url = fileURL()
        let customJSON = #"""
        {"default":"OLD DEFAULT {{transcript}}",
         "overrides":{"com.user.editor":"USER OVERRIDE {{transcript}}"},
         "vocabulary":[{"phonetic":"foo bar","canonical":"FooBar"}]}
        """#
        try write(customJSON, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)
        try store.applyUpgrade(.merge)

        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(obj?["$schemaVersion"] as? Int, PresetStore.bundledSchemaVersion)
        // Default must now match the bundled (which equals PresetStore.defaultPromptTemplate per the drift test).
        XCTAssertEqual(obj?["default"] as? String, PresetStore.defaultPromptTemplate)
        // User overrides preserved verbatim.
        let overrides = obj?["overrides"] as? [String: Any]
        XCTAssertEqual(overrides?["com.user.editor"] as? String, "USER OVERRIDE {{transcript}}")
        // User vocabulary preserved verbatim.
        let vocab = obj?["vocabulary"] as? [[String: String]]
        XCTAssertEqual(vocab?.count, 1)
        XCTAssertEqual(vocab?.first?["phonetic"], "foo bar")
        XCTAssertEqual(vocab?.first?["canonical"], "FooBar")
    }

    func testOverwriteReplacesEverythingWithBundled() throws {
        // Overwrite throws away user customizations — explicit user choice.
        let url = fileURL()
        try write(#"{"default":"OLD","overrides":{"com.user.app":"CUSTOM"},"vocabulary":[{"phonetic":"a","canonical":"B"}]}"#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)
        try store.applyUpgrade(.overwrite)

        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(obj?["default"] as? String, PresetStore.defaultPromptTemplate)
        let overrides = obj?["overrides"] as? [String: Any]
        XCTAssertNil(overrides?["com.user.app"], "user override must be gone after overwrite")
        // Bundled ships overrides for the standard four apps — at least one should be present.
        XCTAssertNotNil(overrides?["com.tinyspeck.slackmacgap"])
    }

    // MARK: - Snippets (v1.1)

    func testSnippetsLoadFromDisk() throws {
        let url = fileURL()
        try write(#"{"default":"X{{transcript}}","snippets":{"sig":"— seemoretmoore","email":"a@b.com"}}"#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)
        XCTAssertEqual(store.snippets(), ["sig": "— seemoretmoore", "email": "a@b.com"])
    }

    func testSnippetsEmptyWhenAbsent() throws {
        let url = fileURL()
        try write(#"{"default":"X{{transcript}}"}"#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)
        XCTAssertEqual(store.snippets(), [:])
    }

    func testSnippetsRejectsTooManyEntries() throws {
        let url = fileURL()
        var pairs: [String] = []
        for i in 0..<(PresetStore.maxSnippets + 1) {
            pairs.append("\"k\(i)\":\"v\"")
        }
        let json = "{\"default\":\"X{{transcript}}\",\"snippets\":{\(pairs.joined(separator: ","))}}"
        try write(json, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)
        XCTAssertEqual(store.snippets(), [:])
        switch store.initialSnippetsWarning {
        case .tooManySnippets: break
        default: XCTFail("expected .tooManySnippets, got \(String(describing: store.initialSnippetsWarning))")
        }
    }

    func testSnippetsRejectsInvalidName() throws {
        let url = fileURL()
        // "the snippet" has a space → invalid name
        try write(#"{"default":"X{{transcript}}","snippets":{"the snippet":"v"}}"#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)
        XCTAssertEqual(store.snippets(), [:])
        switch store.initialSnippetsWarning {
        case .snippetNameInvalid: break
        default: XCTFail("expected .snippetNameInvalid, got \(String(describing: store.initialSnippetsWarning))")
        }
    }

    func testSnippetsRejectsOversizeValue() throws {
        let url = fileURL()
        let bigValue = String(repeating: "x", count: PresetStore.maxSnippetValueBytes + 1)
        try write(#"{"default":"X{{transcript}}","snippets":{"k":"\#(bigValue)"}}"#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)
        XCTAssertEqual(store.snippets(), [:])
        switch store.initialSnippetsWarning {
        case .snippetEntryTooLong: break
        default: XCTFail("expected .snippetEntryTooLong")
        }
    }

    func testSnippetsRejectsArrayShape() throws {
        let url = fileURL()
        try write(#"{"default":"X{{transcript}}","snippets":["bad","shape"]}"#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)
        XCTAssertEqual(store.snippets(), [:])
        switch store.initialSnippetsWarning {
        case .snippetsMalformed: break
        default: XCTFail("expected .snippetsMalformed")
        }
    }

    func testSnippetsAreOptionalAndNullSafe() throws {
        let url = fileURL()
        try write(#"{"default":"X{{transcript}}","snippets":null}"#, to: url)
        let store = PresetStore(fileURL: url, materializeIfMissing: false)
        XCTAssertEqual(store.snippets(), [:])
        XCTAssertNil(store.initialSnippetsWarning, "explicit null must not be a warning")
    }

    // MARK: - expandSnippets

    func testExpandSnippetsReplacesInsertTrigger() {
        let out = PresetStore.expandSnippets(
            in: "thanks insert sig please",
            snippets: ["sig": "— seemoretmoore"]
        )
        XCTAssertEqual(out, "thanks — seemoretmoore please")
    }

    func testExpandSnippetsCaseInsensitiveOnName() {
        let out = PresetStore.expandSnippets(
            in: "Hi please Insert SIG to message",
            snippets: ["sig": "— seemoretmoore"]
        )
        XCTAssertEqual(out, "Hi please — seemoretmoore to message")
    }

    func testExpandSnippetsDoesNotMatchInsideWords() {
        // "insertsig" without a space → no expansion (word boundary check)
        let out = PresetStore.expandSnippets(
            in: "the insertsig token",
            snippets: ["sig": "— seemoretmoore"]
        )
        XCTAssertEqual(out, "the insertsig token")
    }

    func testExpandSnippetsRequiresInsertKeyword() {
        // Bare snippet name without "insert" → no expansion
        let out = PresetStore.expandSnippets(
            in: "the sig is here",
            snippets: ["sig": "— seemoretmoore"]
        )
        XCTAssertEqual(out, "the sig is here")
    }

    func testExpandSnippetsLongestNameWinsFirst() {
        // "sig_long" must be tried before "sig" so "insert sig_long" doesn't
        // expand to "— seemoretmoore_long".
        let out = PresetStore.expandSnippets(
            in: "use insert sig_long today",
            snippets: ["sig": "— seemoretmoore", "sig_long": "— seemoretmoore Moore, MD"]
        )
        XCTAssertEqual(out, "use — seemoretmoore Moore, MD today")
    }

    func testExpandSnippetsEmptyMapIsNoOp() {
        let out = PresetStore.expandSnippets(in: "no snippets here", snippets: [:])
        XCTAssertEqual(out, "no snippets here")
    }

    func testIsValidSnippetNameAcceptsAlnumAndUnderscoreAndDash() {
        XCTAssertTrue(PresetStore.isValidSnippetName("sig"))
        XCTAssertTrue(PresetStore.isValidSnippetName("sig_long"))
        XCTAssertTrue(PresetStore.isValidSnippetName("sig-1"))
        XCTAssertTrue(PresetStore.isValidSnippetName("ABC123"))
    }

    func testIsValidSnippetNameRejectsSpaceDotEmoji() {
        XCTAssertFalse(PresetStore.isValidSnippetName(""))
        XCTAssertFalse(PresetStore.isValidSnippetName("two words"))
        XCTAssertFalse(PresetStore.isValidSnippetName("sig.dot"))
        XCTAssertFalse(PresetStore.isValidSnippetName("sig😀"))
    }

    // MARK: - biasHint (v1.1 Whisper initial_prompt)

    func testBiasHintNilForEmptyVocabulary() {
        XCTAssertNil(PresetStore.biasHint(from: []))
    }

    func testBiasHintCommaJoinsCanonicals() {
        let vocab = [
            VocabEntry(phonetic: "FS event stream", canonical: "FSEventStream"),
            VocabEntry(phonetic: "Swift UI",        canonical: "SwiftUI"),
        ]
        XCTAssertEqual(PresetStore.biasHint(from: vocab), "FSEventStream, SwiftUI")
    }

    func testBiasHintDeduplicatesCanonicals() {
        // Multiple phonetics → same canonical (e.g. Quinn + Clem → Qwen).
        // The hint should list "Qwen" once.
        let vocab = [
            VocabEntry(phonetic: "Quinn", canonical: "Qwen"),
            VocabEntry(phonetic: "Clem",  canonical: "Qwen"),
            VocabEntry(phonetic: "Swift UI", canonical: "SwiftUI"),
        ]
        XCTAssertEqual(PresetStore.biasHint(from: vocab), "Qwen, SwiftUI")
    }

    func testBiasHintPreservesInsertionOrder() {
        let vocab = [
            VocabEntry(phonetic: "a", canonical: "Alpha"),
            VocabEntry(phonetic: "b", canonical: "Beta"),
            VocabEntry(phonetic: "c", canonical: "Gamma"),
        ]
        XCTAssertEqual(PresetStore.biasHint(from: vocab), "Alpha, Beta, Gamma")
    }

    func testBundledExampleJsonHasSchemaVersion() throws {
        // Drift test: bundled JSON must always carry a $schemaVersion that
        // matches the in-code constant. If you bump bundledSchemaVersion, you
        // must also bump the field in presets.example.json.
        let url = try XCTUnwrap(
            Bundle(for: PresetStore.self).url(forResource: "presets.example", withExtension: "json")
        )
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let v = try XCTUnwrap(obj["$schemaVersion"] as? Int, "presets.example.json missing $schemaVersion field")
        XCTAssertEqual(v, PresetStore.bundledSchemaVersion)
    }
}
