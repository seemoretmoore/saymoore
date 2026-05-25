import Foundation

struct TimedSegment: Equatable, Sendable {
    let text: String
    /// whisper.cpp returns segment times in centiseconds (1/100 s).
    let t0Centiseconds: Int64
    let t1Centiseconds: Int64
}

struct TimedTranscript: Equatable, Sendable {
    let segments: [TimedSegment]

    var text: String { segments.map(\.text).joined() }

    /// Split into (head, tail) such that all segments with t1 ≤ cutoff land in
    /// head, all others in tail. Used by StreamingTranscriber to advance the
    /// commit point: head is "stable and frozen", tail is "still revisable".
    func split(atCentiseconds cutoff: Int64) -> (head: TimedTranscript, tail: TimedTranscript) {
        var headSegs: [TimedSegment] = []
        var tailSegs: [TimedSegment] = []
        for s in segments {
            if s.t1Centiseconds <= cutoff { headSegs.append(s) }
            else { tailSegs.append(s) }
        }
        return (TimedTranscript(segments: headSegs), TimedTranscript(segments: tailSegs))
    }
}
