import XCTest
@testable import SayMoore

final class PresetStoreBannerCopyTests: XCTestCase {

    // MARK: - M6: Per-discriminant banner copy

    func testBannerCopyFileUnreadable() {
        let copy = AppDelegate.bannerCopy(for: PresetStoreError.fileUnreadable("oops"))
        XCTAssertEqual(copy, "Couldn't read presets.json — using last-good config.")
    }

    func testBannerCopyMalformedJSON() {
        let copy = AppDelegate.bannerCopy(for: PresetStoreError.malformedJSON("bad"))
        XCTAssertEqual(copy, "presets.json has invalid JSON — using last-good config.")
    }

    func testBannerCopyMissingDefaultKey() {
        let copy = AppDelegate.bannerCopy(for: PresetStoreError.missingDefaultKey)
        XCTAssertEqual(copy, "presets.json missing 'default' entry — using last-good config.")
    }

    func testBannerCopyFileTooLarge() {
        let copy = AppDelegate.bannerCopy(for: PresetStoreError.fileTooLarge(bytes: 600_000))
        XCTAssertEqual(copy, "presets.json is too large (max 512 KB) — using last-good config.")
    }

    func testBannerCopyTooManyOverrides() {
        let copy = AppDelegate.bannerCopy(for: PresetStoreError.tooManyOverrides(count: 150))
        XCTAssertEqual(copy, "Too many app overrides in presets.json (max 100) — using last-good config.")
    }

    func testBannerCopyTemplateTooLong() {
        let copy = AppDelegate.bannerCopy(for: PresetStoreError.templateTooLong(bytes: 20_000))
        XCTAssertEqual(copy, "A presets.json template is too long (max 16 KB) — using last-good config.")
    }

    func testBannerCopyNotRegularFile() {
        let copy = AppDelegate.bannerCopy(for: PresetStoreError.notRegularFile)
        XCTAssertEqual(copy, "presets.json is not a regular file — using last-good config.")
    }

    func testBannerCopyTooManyVocabEntries() {
        let copy = AppDelegate.bannerCopy(for: PresetStoreError.tooManyVocabEntries(count: 51))
        XCTAssertEqual(copy, "Too many vocabulary entries in presets.json (max 50) — vocabulary disabled.")
    }

    func testBannerCopyVocabEntryTooLong() {
        let copy = AppDelegate.bannerCopy(for: PresetStoreError.vocabEntryTooLong(bytes: 65))
        XCTAssertEqual(copy, "A vocabulary entry in presets.json is too long (max 64 bytes) — vocabulary disabled.")
    }

    func testBannerCopyVocabularyTooLarge() {
        let copy = AppDelegate.bannerCopy(for: PresetStoreError.vocabularyTooLarge(bytes: 700))
        XCTAssertEqual(copy, "Vocabulary in presets.json is too large overall (max 512 B) — vocabulary disabled.")
    }

    func testBannerCopyVocabularyMalformed() {
        let copy = AppDelegate.bannerCopy(for: PresetStoreError.vocabularyMalformed)
        XCTAssertEqual(copy, "Vocabulary in presets.json is malformed (expected an array of {phonetic, canonical} entries) — vocabulary disabled.")
    }

    func testBannerCopyUnknownErrorFallback() {
        struct SomeOtherError: Error {}
        let copy = AppDelegate.bannerCopy(for: SomeOtherError())
        XCTAssertEqual(copy, "presets.json error — using last-good config.")
    }

    // MARK: - Verify all PresetStoreError cases are covered (exhaustiveness guard)

    func testAllPresetStoreErrorCasesHaveDistinctCopy() {
        let cases: [PresetStoreError] = [
            .fileUnreadable("x"),
            .malformedJSON("x"),
            .missingDefaultKey,
            .fileTooLarge(bytes: 1),
            .tooManyOverrides(count: 1),
            .templateTooLong(bytes: 1),
            .notRegularFile,
            .tooManyVocabEntries(count: 1),
            .vocabEntryTooLong(bytes: 1),
            .vocabularyTooLarge(bytes: 1),
            .vocabularyMalformed,
        ]
        let copies = cases.map { AppDelegate.bannerCopy(for: $0) }
        let unique = Set(copies)
        XCTAssertEqual(unique.count, cases.count, "each PresetStoreError case must map to unique banner copy")
    }
}
