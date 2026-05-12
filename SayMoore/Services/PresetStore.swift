import Foundation

struct Preset: Equatable, Sendable {
    let name: String
    let promptTemplate: String
}

final class PresetStore: @unchecked Sendable {
    static let defaultPromptTemplate = """
    You are a transcription cleanup assistant. The user dictated text that was transcribed by Whisper.
    Your job: remove filler words (uh, um, like, you know), fix obvious self-corrections (e.g., "Friday — no, Monday" → "Monday"), and produce natural-sounding text in the user's voice.

    Rules:
    - Preserve the user's word choice and phrasing. Do NOT rewrite for style.
    - Do NOT add information that wasn't dictated.
    - Do NOT add commentary, headers, or formatting unless the user explicitly dictated it.
    - Output ONLY the cleaned text. No preamble, no quotes, no explanation.
    - If the input is already clean, return it unchanged.

    Input transcript:
    {{transcript}}
    """

    func defaultPreset() -> Preset {
        Preset(name: "default", promptTemplate: Self.defaultPromptTemplate)
    }

    /// v1: returns the default preset for any bundleID. Slice 4 will introduce overrides.
    func preset(for bundleID: String?) -> Preset {
        _ = bundleID
        return defaultPreset()
    }
}
