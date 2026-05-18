import XCTest
@testable import SayMoore

/// Asserts `PresetStore.applyVocabSubstitutions` correctly replaces phonetic
/// forms with canonical forms — case-insensitive on the phonetic side,
/// word-boundary anchored, longest-match-first ordering.
///
/// This is the post-pivot replacement for the LLM-glossary mechanism. The
/// previous attempt (cleanup-LLM glossary injection) returned 0/6 in manual
/// smoke; deterministic substitution gives reliable results regardless of
/// LLM temperature or instruction-following.
final class VocabSubstitutionTests: XCTestCase {

    private func entry(_ phonetic: String, _ canonical: String) -> VocabEntry {
        VocabEntry(phonetic: phonetic, canonical: canonical)
    }

    // MARK: - Basic substitution

    func testEmptyVocabReturnsTextUnchanged() {
        let out = PresetStore.applyVocabSubstitutions(to: "hello world", vocab: [])
        XCTAssertEqual(out, "hello world")
    }

    func testEmptyTextReturnsEmpty() {
        let out = PresetStore.applyVocabSubstitutions(to: "", vocab: [entry("foo", "Foo")])
        XCTAssertEqual(out, "")
    }

    func testCaseInsensitivePhoneticMatch() {
        let out = PresetStore.applyVocabSubstitutions(
            to: "The FS event stream callback runs.",
            vocab: [entry("fs event stream", "FSEventStream")]
        )
        XCTAssertEqual(out, "The FSEventStream callback runs.")
    }

    func testCanonicalPreservesCase() {
        let out = PresetStore.applyVocabSubstitutions(
            to: "quinn handled cleanup",
            vocab: [entry("Quinn", "Qwen")]
        )
        XCTAssertEqual(out, "Qwen handled cleanup")
    }

    func testMultipleOccurrencesAllReplaced() {
        let out = PresetStore.applyVocabSubstitutions(
            to: "Quinn first, then Quinn again",
            vocab: [entry("Quinn", "Qwen")]
        )
        XCTAssertEqual(out, "Qwen first, then Qwen again")
    }

    // MARK: - Word boundary

    func testWordBoundaryPreventsPartialMatch() {
        // "Quinn" should not match inside "Quinnipiac"
        let out = PresetStore.applyVocabSubstitutions(
            to: "Quinnipiac is a college",
            vocab: [entry("Quinn", "Qwen")]
        )
        XCTAssertEqual(out, "Quinnipiac is a college")
    }

    func testMultiWordPhoneticMatchesAcrossSpaces() {
        let out = PresetStore.applyVocabSubstitutions(
            to: "the AV audio engine attaches the tap",
            vocab: [entry("AV audio engine", "AVAudioEngine")]
        )
        XCTAssertEqual(out, "the AVAudioEngine attaches the tap")
    }

    // MARK: - Multiple entries

    func testMultipleEntriesAllApply() {
        let out = PresetStore.applyVocabSubstitutions(
            to: "The FS event stream uses AV audio engine and Quinn.",
            vocab: [
                entry("FS event stream", "FSEventStream"),
                entry("AV audio engine", "AVAudioEngine"),
                entry("Quinn", "Qwen"),
            ]
        )
        XCTAssertEqual(out, "The FSEventStream uses AVAudioEngine and Qwen.")
    }

    func testLongestMatchWinsWhenOverlapping() {
        // "FS event" is shorter than "FS event stream". With longest-first
        // ordering, the longer phonetic substitutes first.
        let out = PresetStore.applyVocabSubstitutions(
            to: "The FS event stream is here",
            vocab: [
                entry("FS event", "ShortMatch"),
                entry("FS event stream", "FSEventStream"),
            ]
        )
        XCTAssertEqual(out, "The FSEventStream is here")
    }

    // MARK: - Regex-special characters

    func testPhoneticWithRegexSpecialCharsHandledLiterally() {
        // Phonetic containing "." should match literal dot, not any char.
        let out = PresetStore.applyVocabSubstitutions(
            to: "Visit F.S. event today",
            vocab: [entry("F.S. event", "FSEventStream")]
        )
        XCTAssertEqual(out, "Visit FSEventStream today")
    }

    func testCanonicalWithDollarSignHandledLiterally() {
        // "$1" in canonical must not be interpreted as a backreference.
        let out = PresetStore.applyVocabSubstitutions(
            to: "price discount",
            vocab: [entry("discount", "$1 off")]
        )
        XCTAssertEqual(out, "price $1 off")
    }
}
