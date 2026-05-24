import XCTest
@testable import SayMoore

@MainActor
final class SettingsViewModelTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsVMTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        tmpDir = base
    }

    override func tearDown() async throws {
        if let dir = tmpDir { try? FileManager.default.removeItem(at: dir) }
        UserDefaults.standard.removeObject(forKey: "audio.feedback.muted")
        try await super.tearDown()
    }

    private func makeStore(initial: String = #"{"default":"X{{transcript}}"}"#) throws -> PresetStore {
        let url = tmpDir.appendingPathComponent("presets.json")
        try initial.data(using: .utf8)!.write(to: url, options: .atomic)
        return PresetStore(fileURL: url, materializeIfMissing: false)
    }

    func testInitPopulatesVocabFromPresetStore() throws {
        let json = #"""
        {"default":"X{{transcript}}",
         "vocabulary":[{"phonetic":"Quinn","canonical":"Qwen"},
                       {"phonetic":"Swift UI","canonical":"SwiftUI"}]}
        """#
        let store = try makeStore(initial: json)
        let vm = SettingsViewModel(presets: store)
        XCTAssertEqual(vm.vocab.count, 2)
        XCTAssertEqual(vm.vocab.map(\.phonetic).sorted(), ["Quinn", "Swift UI"])
        XCTAssertEqual(vm.vocab.map(\.canonical).sorted(), ["Qwen", "SwiftUI"])
    }

    func testCommitVocabularyWritesToDiskAndReloadCanSeeIt() throws {
        let store = try makeStore()
        let vm = SettingsViewModel(presets: store)
        vm.addVocabRow()
        vm.vocab[0].phonetic = "Quinn"
        vm.vocab[0].canonical = "Qwen"

        XCTAssertTrue(vm.commitVocabulary())
        XCTAssertNil(vm.lastError)

        // Re-read from disk via a fresh PresetStore — the entry must be there.
        let url = tmpDir.appendingPathComponent("presets.json")
        let fresh = PresetStore(fileURL: url, materializeIfMissing: false)
        XCTAssertEqual(fresh.vocabulary(), [VocabEntry(phonetic: "Quinn", canonical: "Qwen")])
    }

    func testCommitVocabularyDropsBlankRows() throws {
        let store = try makeStore()
        let vm = SettingsViewModel(presets: store)
        vm.addVocabRow()
        vm.vocab[0].phonetic = "Quinn"
        vm.vocab[0].canonical = "Qwen"
        vm.addVocabRow()                // blank row — must be dropped
        vm.addVocabRow()
        vm.vocab[2].phonetic = "  "     // whitespace-only — must be dropped
        vm.vocab[2].canonical = "X"

        XCTAssertTrue(vm.commitVocabulary())
        let url = tmpDir.appendingPathComponent("presets.json")
        let fresh = PresetStore(fileURL: url, materializeIfMissing: false)
        XCTAssertEqual(fresh.vocabulary().count, 1)
    }

    func testCommitVocabularyFailsOnTooManyEntries() throws {
        let store = try makeStore()
        let vm = SettingsViewModel(presets: store)
        for i in 0...PresetStore.maxVocabularyEntries {
            vm.addVocabRow()
            vm.vocab[i].phonetic = "p\(i)"
            vm.vocab[i].canonical = "C\(i)"
        }
        XCTAssertFalse(vm.commitVocabulary())
        XCTAssertNotNil(vm.lastError)
        XCTAssertTrue(vm.lastError?.contains("Too many") ?? false)
    }

    func testCommitVocabularyFailsOnOversizeEntry() throws {
        let store = try makeStore()
        let vm = SettingsViewModel(presets: store)
        vm.addVocabRow()
        vm.vocab[0].phonetic = String(repeating: "x", count: PresetStore.maxVocabularyEntryBytes + 1)
        vm.vocab[0].canonical = "y"
        XCTAssertFalse(vm.commitVocabulary())
        XCTAssertTrue(vm.lastError?.contains("too long") ?? false)
    }

    func testCommitVocabularyFailsOnTotalSizeExceeded() throws {
        let store = try makeStore()
        let vm = SettingsViewModel(presets: store)
        // Each entry: 60-byte phonetic + 1-byte canonical = 61 billed bytes.
        // 10 entries = 610 bytes > 512 cap.
        let big = String(repeating: "x", count: 60)
        for i in 0..<10 {
            vm.addVocabRow()
            vm.vocab[i].phonetic = big
            vm.vocab[i].canonical = "\(i)"
        }
        XCTAssertFalse(vm.commitVocabulary())
        XCTAssertTrue(vm.lastError?.contains("too large") ?? false)
    }

    func testMutedTogglePersistsToUserDefaults() throws {
        let store = try makeStore()
        let vm = SettingsViewModel(presets: store)
        XCTAssertFalse(vm.muted)
        vm.muted = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "audio.feedback.muted"))
        vm.muted = false
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "audio.feedback.muted"))
    }

    func testRefreshPicksUpExternalEdits() throws {
        let store = try makeStore()
        let vm = SettingsViewModel(presets: store)
        XCTAssertEqual(vm.vocab.count, 0)

        // External write: simulate the user hand-editing the file.
        let url = tmpDir.appendingPathComponent("presets.json")
        let updated = #"""
        {"default":"X{{transcript}}",
         "vocabulary":[{"phonetic":"AB","canonical":"CD"}]}
        """#
        try updated.data(using: .utf8)!.write(to: url, options: .atomic)
        try store.reload()
        vm.refresh()
        XCTAssertEqual(vm.vocab.count, 1)
        XCTAssertEqual(vm.vocab[0].phonetic, "AB")
    }

    // MARK: - PresetStore.setVocabulary (called by the view model)

    func testSetVocabularyPreservesOtherTopLevelFields() throws {
        let json = #"""
        {"$schemaVersion":1,
         "default":"D{{transcript}}",
         "overrides":{"com.x.y":"OVERRIDE {{transcript}}"},
         "snippets":{"sig":"— Alex"},
         "vocabulary":[{"phonetic":"old","canonical":"OLD"}]}
        """#
        let store = try makeStore(initial: json)
        try store.setVocabulary([VocabEntry(phonetic: "new", canonical: "NEW")])

        let url = tmpDir.appendingPathComponent("presets.json")
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(obj?["$schemaVersion"] as? Int, 1)
        XCTAssertEqual(obj?["default"] as? String, "D{{transcript}}")
        let overrides = obj?["overrides"] as? [String: Any]
        XCTAssertEqual(overrides?["com.x.y"] as? String, "OVERRIDE {{transcript}}")
        let snippets = obj?["snippets"] as? [String: Any]
        XCTAssertEqual(snippets?["sig"] as? String, "— Alex")
        let vocab = obj?["vocabulary"] as? [[String: String]]
        XCTAssertEqual(vocab?.count, 1)
        XCTAssertEqual(vocab?.first?["phonetic"], "new")
    }

    // MARK: - P1 fixes from adversarial review

    func testRefreshPreservesUUIDsForUnchangedRows() throws {
        let json = #"""
        {"default":"X{{transcript}}",
         "vocabulary":[{"phonetic":"Quinn","canonical":"Qwen"},
                       {"phonetic":"Swift UI","canonical":"SwiftUI"}]}
        """#
        let store = try makeStore(initial: json)
        let vm = SettingsViewModel(presets: store)
        let originalIDs = vm.vocab.map(\.id)
        vm.refresh() // re-read same on-disk state
        let afterIDs = vm.vocab.map(\.id)
        XCTAssertEqual(originalIDs, afterIDs,
                       "refresh must preserve row UUIDs when (phonetic, canonical) is unchanged — otherwise SwiftUI Table rotates IDs and loses focus/selection")
    }

    func testRefreshAssignsNewUUIDsForAddedRows() throws {
        let store = try makeStore()
        let vm = SettingsViewModel(presets: store)
        XCTAssertEqual(vm.vocab.count, 0)

        // External write adds a vocab entry.
        let url = tmpDir.appendingPathComponent("presets.json")
        let updated = #"""
        {"default":"X{{transcript}}",
         "vocabulary":[{"phonetic":"NEW","canonical":"New"}]}
        """#
        try updated.data(using: .utf8)!.write(to: url, options: .atomic)
        try store.reload()
        vm.refresh()
        XCTAssertEqual(vm.vocab.count, 1)
        // The new row gets a fresh UUID (no precondition to preserve since
        // nothing matches the new (phonetic, canonical)).
        XCTAssertNotEqual(vm.vocab[0].id, UUID())
    }

    func testCommitVocabularyDoesNotRotateUUIDs() throws {
        let store = try makeStore()
        let vm = SettingsViewModel(presets: store)
        vm.addVocabRow()
        vm.vocab[0].phonetic = "P"
        vm.vocab[0].canonical = "C"
        let originalID = vm.vocab[0].id

        XCTAssertTrue(vm.commitVocabulary())
        // commitVocabulary must NOT call refresh — in-memory is authoritative
        // post-save. If refresh were called, the row UUID would rotate.
        XCTAssertEqual(vm.vocab[0].id, originalID,
                       "Save must not rotate row UUIDs (would break TextField focus)")
    }

    func testAddVocabRowClearsLastError() throws {
        let store = try makeStore()
        let vm = SettingsViewModel(presets: store)
        // Force an error.
        vm.addVocabRow()
        vm.vocab[0].phonetic = String(repeating: "x", count: PresetStore.maxVocabularyEntryBytes + 1)
        vm.vocab[0].canonical = "y"
        XCTAssertFalse(vm.commitVocabulary())
        XCTAssertNotNil(vm.lastError)

        // User starts editing — error should clear so they don't stare at
        // stale red text while fixing.
        vm.addVocabRow()
        XCTAssertNil(vm.lastError)
    }

    func testRemoveVocabRowClearsLastError() throws {
        let store = try makeStore()
        let vm = SettingsViewModel(presets: store)
        vm.addVocabRow()
        vm.vocab[0].phonetic = String(repeating: "x", count: PresetStore.maxVocabularyEntryBytes + 1)
        vm.vocab[0].canonical = "y"
        XCTAssertFalse(vm.commitVocabulary())
        XCTAssertNotNil(vm.lastError)

        vm.removeVocabRow(vm.vocab[0])
        XCTAssertNil(vm.lastError)
    }

    func testSetVocabularyRejectsOversizeWithoutTouchingFile() throws {
        let store = try makeStore()
        let url = tmpDir.appendingPathComponent("presets.json")
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(
            try store.setVocabulary([
                VocabEntry(
                    phonetic: String(repeating: "x", count: PresetStore.maxVocabularyEntryBytes + 1),
                    canonical: "y"
                )
            ])
        )
        let after = try Data(contentsOf: url)
        XCTAssertEqual(before, after, "failed write must leave disk untouched")
    }
}
