import Foundation

struct TranscriptSegment: Equatable, Sendable {
    let text: String
    let noSpeechProb: Float
}

struct Transcript: Equatable, Sendable {
    let text: String
    let averageNoSpeechProb: Float

    static let garbageThreshold: Float = 0.90

    var isGarbage: Bool {
        averageNoSpeechProb > Self.garbageThreshold
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
