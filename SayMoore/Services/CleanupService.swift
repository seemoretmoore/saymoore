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
        return response.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func buildPrompt(template: String, transcript: String) -> String {
        let fenced = "<transcript>\n\(transcript)\n</transcript>"
        return template.replacingOccurrences(of: "{{transcript}}", with: fenced)
    }
}
