import XCTest
@testable import SayMoore

@MainActor
final class VocabSuggesterTests: XCTestCase {

    // MARK: - candidates(in:)

    func testCandidatesMatchesPascalCase() {
        let out = VocabSuggester.candidates(in: "use FooBar for the demo")
        XCTAssertEqual(out, ["FooBar"])
    }

    func testCandidatesMatchesMixedCamelCase() {
        // AVAudioEngine — leading caps run then mixed
        let out = VocabSuggester.candidates(in: "call AVAudioEngine right away")
        XCTAssertTrue(out.contains("AVAudioEngine"))
    }

    func testCandidatesMatchesScreamingSnake() {
        let out = VocabSuggester.candidates(in: "set API_KEY then exit")
        XCTAssertTrue(out.contains("API_KEY"))
    }

    func testCandidatesMatchesAllCapsFourPlusLetters() {
        // ALL CAPS pattern alone (no mixed-case variant in the same string)
        let out = VocabSuggester.candidates(in: "use GRAPHQL today please")
        XCTAssertTrue(out.contains("GRAPHQL"))
    }

    func testCandidatesDedupesAcrossPatternsByLowercase() {
        // When the same term appears in two casings, the first match wins
        // (dedupe is keyed on lowercase). PascalCase pattern fires before
        // the all-caps pattern, so "GraphQL" survives.
        let out = VocabSuggester.candidates(in: "use GraphQL and GRAPHQL together")
        XCTAssertEqual(out.filter { $0.lowercased() == "graphql" }.count, 1)
        XCTAssertEqual(out.first(where: { $0.lowercased() == "graphql" }), "GraphQL")
    }

    func testCandidatesSkipsTwoAndThreeLetterAllCaps() {
        // "USA" / "OK" / "TV" must NOT match — too noisy.
        let out = VocabSuggester.candidates(in: "in USA the TV showed OK")
        XCTAssertFalse(out.contains("USA"))
        XCTAssertFalse(out.contains("TV"))
        XCTAssertFalse(out.contains("OK"))
    }

    func testCandidatesSkipsSingleCapitalProperNoun() {
        // "seemoretmoore" alone is too noisy — every dictation has a sentence-start cap.
        let out = VocabSuggester.candidates(in: "seemoretmoore went home")
        XCTAssertFalse(out.contains("seemoretmoore"))
    }

    func testCandidatesDeduplicatesByLowercaseFirstAppearance() {
        // Same term twice → one entry, first casing preserved.
        let out = VocabSuggester.candidates(in: "use GraphQL with GraphQL today")
        // exactly one "GraphQL" entry
        XCTAssertEqual(out.filter { $0.lowercased() == "graphql" }.count, 1)
    }

    func testCandidatesEmptyTextEmptyOutput() {
        XCTAssertEqual(VocabSuggester.candidates(in: ""), [])
    }

    // MARK: - blockedKeys

    func testBlockedKeysFromVocabularyIncludesBothColumnsLowercased() {
        let vocab = [
            VocabEntry(phonetic: "Quinn", canonical: "Qwen"),
            VocabEntry(phonetic: "Swift UI", canonical: "SwiftUI"),
        ]
        let keys = VocabSuggester.blockedKeys(from: vocab)
        XCTAssertTrue(keys.contains("quinn"))
        XCTAssertTrue(keys.contains("qwen"))
        XCTAssertTrue(keys.contains("swift ui"))
        XCTAssertTrue(keys.contains("swiftui"))
    }

    // MARK: - consider (statefulness)

    func testConsiderSurfacesFirstNewCandidate() {
        let s = VocabSuggester()
        let result = s.consider(
            cleanedText: "use GraphQL today",
            existingVocab: []
        )
        XCTAssertEqual(result, "GraphQL")
    }

    func testConsiderReturnsNilWhenAllCandidatesInVocab() {
        let s = VocabSuggester()
        let result = s.consider(
            cleanedText: "use GraphQL today",
            existingVocab: [VocabEntry(phonetic: "graph QL", canonical: "GraphQL")]
        )
        XCTAssertNil(result, "term already in vocabulary must not re-suggest")
    }

    func testConsiderDeduplicatesAcrossCalls() {
        let s = VocabSuggester()
        XCTAssertEqual(s.consider(cleanedText: "use GraphQL today", existingVocab: []), "GraphQL")
        XCTAssertNil(
            s.consider(cleanedText: "use GraphQL again", existingVocab: []),
            "second appearance of same term must not re-suggest within a session"
        )
    }

    func testConsiderReturnsNilWhenNoCandidates() {
        let s = VocabSuggester()
        XCTAssertNil(s.consider(cleanedText: "hello world", existingVocab: []))
    }

    func testConsiderSkipsCandidatesAlreadySuggestedButSurfacesNextOne() {
        let s = VocabSuggester()
        XCTAssertEqual(
            s.consider(cleanedText: "use GraphQL and FooBar today", existingVocab: []),
            "GraphQL",
            "first call returns the first candidate"
        )
        XCTAssertEqual(
            s.consider(cleanedText: "use GraphQL and FooBar today", existingVocab: []),
            "FooBar",
            "second call surfaces the next not-yet-suggested candidate"
        )
        XCTAssertNil(
            s.consider(cleanedText: "use GraphQL and FooBar today", existingVocab: []),
            "third call has nothing new to surface"
        )
    }

    func testConsiderCaseInsensitiveAgainstVocabulary() {
        let s = VocabSuggester()
        let result = s.consider(
            cleanedText: "test GRAPHQL today",
            existingVocab: [VocabEntry(phonetic: "graph QL", canonical: "graphql")]
        )
        XCTAssertNil(result, "lowercase canonical must block uppercase candidate")
    }

    func testResetClearsSuggestedSet() {
        let s = VocabSuggester()
        _ = s.consider(cleanedText: "use GraphQL", existingVocab: [])
        s.resetSuggestedSet()
        XCTAssertEqual(
            s.consider(cleanedText: "use GraphQL", existingVocab: []),
            "GraphQL",
            "reset must allow re-suggesting"
        )
    }
}
