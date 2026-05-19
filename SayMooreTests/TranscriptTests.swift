import XCTest
@testable import SayMoore

final class TranscriptTests: XCTestCase {
    func testJoinsSegmentTextsAndStripsLeadingWhitespace() {
        let r = Transcript.fromSegments([
            TranscriptSegment(text: " Hello ",          noSpeechProb: 0.05),
            TranscriptSegment(text: " world.",          noSpeechProb: 0.10)
        ])
        XCTAssertEqual(r.text, "Hello world.")
    }

    func testAverageNoSpeechProbAcrossSegments() {
        let r = Transcript.fromSegments([
            TranscriptSegment(text: "a", noSpeechProb: 0.10),
            TranscriptSegment(text: "b", noSpeechProb: 0.30),
            TranscriptSegment(text: "c", noSpeechProb: 0.50),
        ])
        XCTAssertEqual(r.averageNoSpeechProb, 0.30, accuracy: 0.0001)
    }

    func testEmptySegmentsProducesEmptyTextZeroProb() {
        let r = Transcript.fromSegments([])
        XCTAssertEqual(r.text, "")
        XCTAssertEqual(r.averageNoSpeechProb, 0.0)
    }

    func testIsGarbageWhenAvgNoSpeechProbAboveThreshold() {
        let r = Transcript.fromSegments([
            TranscriptSegment(text: "real speech", noSpeechProb: 0.70),
            TranscriptSegment(text: "real speech", noSpeechProb: 0.80),
        ])
        XCTAssertTrue(r.isGarbage) // 0.75 avg > 0.60 threshold
    }

    func testIsNotGarbageAtBoundary() {
        let r = Transcript.fromSegments([
            TranscriptSegment(text: "real speech", noSpeechProb: 0.60),
        ])
        XCTAssertFalse(r.isGarbage) // strict >, not >=
    }

    func testIsNotGarbageForLowProb() {
        let r = Transcript.fromSegments([
            TranscriptSegment(text: "hello", noSpeechProb: 0.05)
        ])
        XCTAssertFalse(r.isGarbage)
    }

    func testIsGarbageForKnownHallucinationsEvenAtLowProb() {
        // Whisper sometimes emits stock phrases on silence with deceptively low
        // noSpeechProb — the denylist catches them regardless of prob.
        for phrase in [
            "Thank you.", "thank you", "Thanks for watching.", "you", ".", "  Thank you.  ",
            "I'm sorry.", "I'm sorry", "  i'm sorry  ", "Sorry.",
        ] {
            let r = Transcript.fromSegments([
                TranscriptSegment(text: phrase, noSpeechProb: 0.10)
            ])
            XCTAssertTrue(r.isGarbage, "expected '\(phrase)' to be flagged as hallucination")
        }
    }

    func testRealSentenceEndingInThankYouIsNotGarbage() {
        // Denylist is exact whole-utterance match — a real sentence containing
        // "thank you" as a tail is preserved.
        let r = Transcript.fromSegments([
            TranscriptSegment(text: "I appreciate the review, thank you.", noSpeechProb: 0.10)
        ])
        XCTAssertFalse(r.isGarbage)
    }

    func testWordCountUsedForFastPath() {
        XCTAssertEqual(Transcript(text: "yes", averageNoSpeechProb: 0).wordCount, 1)
        XCTAssertEqual(Transcript(text: "  ok thanks  ", averageNoSpeechProb: 0).wordCount, 2)
        XCTAssertEqual(Transcript(text: "", averageNoSpeechProb: 0).wordCount, 0)
        XCTAssertEqual(Transcript(text: "hello world how are you", averageNoSpeechProb: 0).wordCount, 5)
    }
}
