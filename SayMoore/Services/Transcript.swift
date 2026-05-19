import Foundation

struct TranscriptSegment: Equatable, Sendable {
    let text: String
    let noSpeechProb: Float
}

struct Transcript: Equatable, Sendable {
    let text: String
    let averageNoSpeechProb: Float

    static let garbageThreshold: Float = 0.60

    // Whisper stock hallucinations on silence / near-silence. Compared case-insensitively
    // against the trimmed transcript. Match is exact (whole-utterance), not substring —
    // a real sentence ending in "thank you." is preserved.
    static let hallucinations: Set<String> = [
        "",
        ".",
        "you",
        "you.",
        "thank you",
        "thank you.",
        "thanks",
        "thanks.",
        "thanks for watching",
        "thanks for watching.",
        "thanks for watching!",
        "i'm sorry",
        "i'm sorry.",
        "sorry.",
        "[blank_audio]",
        "(silence)",
        "bye",
        "bye.",
        "bye!",
    ]

    var isGarbage: Bool {
        if averageNoSpeechProb > Self.garbageThreshold { return true }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Self.hallucinations.contains(normalized)
    }

    var wordCount: Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    static func fromSegments(_ segments: [TranscriptSegment]) -> Transcript {
        guard !segments.isEmpty else {
            return Transcript(text: "", averageNoSpeechProb: 0)
        }
        let joined = segments
            .map { $0.text.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let avg = segments.reduce(Float(0)) { $0 + $1.noSpeechProb } / Float(segments.count)
        return Transcript(text: joined, averageNoSpeechProb: avg)
    }
}
