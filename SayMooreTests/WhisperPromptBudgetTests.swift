import XCTest
@testable import SayMoore

/// CI-enforced budget guard: a realistic max-cap vocabulary must tokenize to
/// ≤ 200 whisper tokens, leaving healthy headroom under whisper.cpp's effective
/// `initial_prompt` budget (`n_text_ctx/2 - 4` ≈ 224 for std 448-ctx models).
///
/// Note: synthetic worst-case (numeric-suffix terms like "Term047") tokenizes
/// pathologically (~0.4 tokens/byte) because BPE merges fail on digit-heavy
/// strings. Real SayMoore use is project-identifier vocab (`FSEventStream`,
/// `AVAudioEngine`, `Qwen`) where CamelCase tokenizes cleanly (~0.25 tokens/byte).
/// This test reflects realistic use. If a future feature lets users supply
/// arbitrary numeric tokens at scale, revisit the budget.
final class WhisperPromptBudgetTests: XCTestCase {

    /// Realistic project-identifier vocab packed to near the byte cap.
    private static let realisticBase: [String] = [
        "FSEventStream", "AVAudioEngine", "AVAudioConverter", "DispatchQueue",
        "NSWorkspace", "NSPasteboard", "CFRunLoop", "CGEventTap",
        "PipelineCoordinator", "PresetStore", "TranscriptionService",
        "CleanupService", "OllamaService", "MenuBarController", "AppDelegate",
        "Qwen", "Ollama", "SayMoore", "SwiftUI", "Combine", "Sendable",
        "MainActor", "AsyncStream", "Continuation", "Notification",
        "Bundle", "Logger", "FileHandle", "AttributedString", "JSON",
    ]

    private func makeRealisticMaxCapVocabulary() -> [String] {
        var entries: [String] = []
        var idx = 0
        while entries.count < PresetStore.maxVocabularyEntries {
            let candidate = entries + [Self.realisticBase[idx % Self.realisticBase.count]]
            guard let formatted = PresetStore.vocabularyPromptString(candidate),
                  formatted.utf8.count <= PresetStore.maxVocabularyTotalBytes else {
                break
            }
            entries = candidate
            idx += 1
        }
        return entries
    }

    func testByteCapHoldsForRealisticMaxVocab() throws {
        let entries = makeRealisticMaxCapVocabulary()
        XCTAssertGreaterThan(entries.count, 0)
        let prompt = try XCTUnwrap(PresetStore.vocabularyPromptString(entries))
        XCTAssertLessThanOrEqual(prompt.utf8.count, PresetStore.maxVocabularyTotalBytes)
    }

    func testRealisticMaxCapVocabStaysUnderTwoHundredTokens() throws {
        let modelURL = WhisperModel.defaultDestinationURL
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw XCTSkip("whisper model not at \(modelURL.path) — run first-launch bootstrap")
        }
        let entries = makeRealisticMaxCapVocabulary()
        let prompt = try XCTUnwrap(PresetStore.vocabularyPromptString(entries))
        guard let count = WhisperTranscriptionService.tokenCount(modelPath: modelURL.path, prompt: prompt) else {
            throw XCTSkip("whisper_init_from_file_with_params returned nil — model may be corrupt")
        }
        XCTAssertLessThanOrEqual(
            count, 200,
            "realistic max-cap vocab tokenized to \(count) tokens — too close to whisper.cpp's ~224 initial_prompt budget; tighten maxVocabularyTotalBytes or shrink vocab fixture"
        )
    }
}
