import Foundation

/// Watches the cleaned text of every successful dictation for proper-noun-like
/// tokens (camelCase / PascalCase / SCREAMING_SNAKE / ALL CAPS ≥4 letters) that
/// don't already appear in the user's vocabulary, and surfaces the first new
/// candidate as a low-priority notification.
///
/// Per-session dedupe (in-memory only). A term suggested once won't re-fire
/// until the app relaunches. Future polish: persist the "dismissed" set to
/// disk so the suggestion doesn't bounce across sessions.
@MainActor
final class VocabSuggester {
    private var alreadySuggested: Set<String> = []

    /// Inspect `cleanedText` against `existingVocab`. Returns the first
    /// not-yet-suggested candidate term, or `nil` if no qualifying term is
    /// present (or all candidates were already suggested this session).
    /// The returned term is the user's original casing so the suggestion
    /// banner shows "GraphQL", not "graphql".
    func consider(cleanedText: String, existingVocab: [VocabEntry]) -> String? {
        let candidates = Self.candidates(in: cleanedText)
        let blocked = Self.blockedKeys(from: existingVocab)
        for term in candidates {
            let key = term.lowercased()
            if blocked.contains(key) { continue }
            if alreadySuggested.contains(key) { continue }
            alreadySuggested.insert(key)
            return term
        }
        return nil
    }

    /// Manual reset (e.g. when the user adds the term and we want to allow
    /// future suggestions on new patterns). Not currently wired but cheap
    /// to keep for the eventual Settings UI integration.
    func resetSuggestedSet() {
        alreadySuggested.removeAll()
    }

    /// Lowercase set of every phonetic + canonical from `vocab`. The
    /// suggester compares its candidates against this set so terms the user
    /// has already added (under either column) don't bounce as suggestions.
    static func blockedKeys(from vocab: [VocabEntry]) -> Set<String> {
        var s = Set<String>()
        for e in vocab {
            s.insert(e.phonetic.lowercased())
            s.insert(e.canonical.lowercased())
        }
        return s
    }

    /// Extract proper-noun-like terms from `text`. Three patterns:
    ///   - PascalCase / mixed camelCase with at least one internal uppercase
    ///     run after lowercase (e.g. "FooBar", "AVAudioEngine"). Single-cap
    ///     words like "Tracy" are NOT matched — too noisy.
    ///   - SCREAMING_SNAKE_CASE with at least one underscore (e.g. "API_KEY").
    ///   - ALL-CAPS words ≥4 letters (e.g. "GRAPHQL"). 2- and 3-letter
    ///     all-caps are skipped — too many false positives ("OK", "USA").
    ///
    /// Each pattern is matched independently; results are de-duplicated by
    /// the term's lowercase form but the FIRST appearance casing is kept so
    /// banners display the user's intended spelling.
    static func candidates(in text: String) -> [String] {
        let patterns = [
            // Pattern 1: mixed-case identifier-like — must have at least one
            // lower→upper transition. Anchored at the start of a word.
            #"\b[A-Z][a-z]+(?:[A-Z][a-zA-Z0-9]*)+\b"#,
            // Pattern 1b: leading caps run followed by lower (AVAudio → AVAudioEngine still matches Pattern 1 but a leading-caps form like "AVAudio" is covered here).
            #"\b[A-Z]{2,}[a-z][a-zA-Z0-9]+\b"#,
            // Pattern 2: SCREAMING_SNAKE_CASE
            #"\b[A-Z][A-Z0-9]+(?:_[A-Z0-9]+)+\b"#,
            // Pattern 3: ALL-CAPS ≥4 letters (so "USA"/"OK" are skipped)
            #"\b[A-Z]{4,}\b"#,
        ]
        var seen = Set<String>()
        var out: [String] = []
        for p in patterns {
            guard let regex = try? NSRegularExpression(pattern: p, options: []) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
                guard let m = match, let r = Range(m.range, in: text) else { return }
                let term = String(text[r])
                let key = term.lowercased()
                if !seen.contains(key) {
                    seen.insert(key)
                    out.append(term)
                }
            }
        }
        return out
    }
}
