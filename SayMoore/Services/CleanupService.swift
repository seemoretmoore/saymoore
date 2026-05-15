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
        let vocab = presets.vocabulary()
        let prompt = Self.buildPrompt(template: preset.promptTemplate, transcript: raw, vocabulary: vocab)
        Log.cleanup.debug("cleanup → preset=\(preset.name, privacy: .public) chars=\(raw.count, privacy: .public) vocabCount=\(vocab.count, privacy: .public)")
        let response = try await client.generate(model: model, prompt: prompt, timeout: timeout)
        return response.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func buildPrompt(template: String, transcript: String, vocabulary: [String]) -> String {
        let safe = transcript
            .replacingOccurrences(of: "</transcript>", with: "</\u{200B}transcript>")
            .replacingOccurrences(of: "<transcript>", with: "<\u{200B}transcript>")
        var fenced = "<transcript>\n\(safe)\n</transcript>"
        if let glossary = PresetStore.cleanupGlossaryLine(vocabulary) {
            fenced = "\(glossary)\n\n\(fenced)"
        }
        return template.replacingOccurrences(of: "{{transcript}}", with: fenced)
    }
}
