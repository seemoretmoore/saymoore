import Foundation

protocol TranscriptCleaning: Sendable {
    func clean(_ raw: String, bundleID: String?) async throws -> String
}

final class CleanupService: TranscriptCleaning, @unchecked Sendable {
    static let defaultModel = "qwen2.5:7b-instruct"
    static let defaultTimeout: TimeInterval = 10

    private let client: OllamaClient
    private let model: String
    private let presets: PresetResolving
    private let timeout: TimeInterval

    init(
        client: OllamaClient,
        model: String = CleanupService.defaultModel,
        presets: PresetResolving,
        timeout: TimeInterval = CleanupService.defaultTimeout
    ) {
        self.client = client
        self.model = model
        self.presets = presets
        self.timeout = timeout
    }

    func clean(_ raw: String, bundleID: String?) async throws -> String {
        let preset = presets.preset(for: bundleID)
        let prompt = Self.buildPrompt(template: preset.promptTemplate, transcript: raw)
        Log.cleanup.debug("cleanup → preset=\(preset.name, privacy: .public) chars=\(raw.count, privacy: .public)")
        let response = try await client.generate(model: model, prompt: prompt, timeout: timeout)
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        try Self.validate(cleaned: trimmed, raw: raw)
        return trimmed
    }

    // Throws .cleanupFailed when the LLM returned a placeholder/meta-commentary
    // response or collapsed the input. The pipeline's runCleanup catches this
    // and falls back to pasting the raw transcript.
    enum ValidationFailure: String, Sendable {
        case empty
        case placeholder
        case lengthCollapse
    }

    private static let placeholderResponses: Set<String> = [
        "n/a",
        "nothing to clean",
        "nothing to clean here",
        "no changes needed",
        "no change needed",
        "unable to clean",
        "i cannot help with that",
        "i can't help with that",
    ]

    static func validate(cleaned: String, raw: String) throws {
        if cleaned.isEmpty {
            Log.cleanup.error("cleanup rejected: empty response")
            throw SayMooreError.cleanupFailed(underlying: NSError(
                domain: "CleanupService.Validation",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: ValidationFailure.empty.rawValue]
            ))
        }
        let lowered = cleaned.lowercased().trimmingCharacters(in: .punctuationCharacters)
        if placeholderResponses.contains(lowered) {
            Log.cleanup.error("cleanup rejected: placeholder response (\(cleaned, privacy: .public))")
            throw SayMooreError.cleanupFailed(underlying: NSError(
                domain: "CleanupService.Validation",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: ValidationFailure.placeholder.rawValue]
            ))
        }
        // Length-collapse floor: only applies when raw is non-trivial, to avoid
        // false positives on legitimately short cleanups (e.g. "Yes." → "Yes.").
        if raw.count >= 10, Double(cleaned.count) < Double(raw.count) * 0.20 {
            Log.cleanup.error("cleanup rejected: length collapse (raw=\(raw.count) cleaned=\(cleaned.count))")
            throw SayMooreError.cleanupFailed(underlying: NSError(
                domain: "CleanupService.Validation",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: ValidationFailure.lengthCollapse.rawValue]
            ))
        }
    }

    static func buildPrompt(template: String, transcript: String) -> String {
        let safe = transcript
            .replacingOccurrences(of: "</transcript>", with: "</\u{200B}transcript>")
            .replacingOccurrences(of: "<transcript>", with: "<\u{200B}transcript>")
        let fenced = "<transcript>\n\(safe)\n</transcript>"
        return template.replacingOccurrences(of: "{{transcript}}", with: fenced)
    }
}
