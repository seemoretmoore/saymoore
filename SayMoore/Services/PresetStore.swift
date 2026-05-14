import Foundation

struct Preset: Equatable, Sendable {
    let name: String
    let promptTemplate: String
}

enum PresetStoreError: Error, Equatable {
    case fileUnreadable(String)
    case malformedJSON(String)
    case missingDefaultKey
}

final class PresetStore: @unchecked Sendable {
    static let defaultPromptTemplate = """
    You are a transcription cleanup assistant. The user dictated text that was transcribed by Whisper.
    Your job: remove filler words (uh, um, like, you know), fix obvious self-corrections (e.g., "X — no, Y" → "Y"), fix punctuation and capitalization so the text reads as natural written English, and produce natural-sounding text in the user's voice.

    Rules:
    - Preserve the user's word choice and phrasing. Do NOT rewrite for style.
    - You MAY add or correct punctuation (periods, commas, question marks, apostrophes) and capitalization (sentence starts, "I", proper nouns). These are not style rewrites.
    - Do NOT add information that wasn't dictated.
    - Do NOT add commentary, headers, or formatting unless the user explicitly dictated it.
    - Output ONLY the cleaned text. No preamble, no quotes, no explanation.
    - If the input is already clean, return it unchanged.

    Input transcript:
    {{transcript}}
    """

    static var defaultFileURL: URL {
        let app = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return app
            .appendingPathComponent("SayMoore", isDirectory: true)
            .appendingPathComponent("presets.json", isDirectory: false)
    }

    private let fileURL: URL
    private let lock = NSLock()
    private var currentDefault: Preset

    /// Production initializer. Ensures the preset directory exists, materializes
    /// `presets.json` with the current hardcoded baseline on first launch, and
    /// loads the on-disk default. Load errors fall back to the hardcoded baseline.
    convenience init() {
        self.init(fileURL: Self.defaultFileURL, materializeIfMissing: true)
    }

    /// Designated initializer. `materializeIfMissing=false` for tests that want
    /// to start from a specific on-disk state.
    init(fileURL: URL, materializeIfMissing: Bool) {
        self.fileURL = fileURL
        self.currentDefault = Preset(name: "default", promptTemplate: Self.defaultPromptTemplate)

        if materializeIfMissing {
            try? Self.ensureDirectory(for: fileURL)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try? Self.writeBaselineFile(at: fileURL)
            }
        }

        // Best-effort initial load; on failure we keep the hardcoded baseline.
        if let loaded = try? Self.loadFromDisk(at: fileURL) {
            self.currentDefault = loaded
        }
    }

    func defaultPreset() -> Preset {
        lock.lock(); defer { lock.unlock() }
        return currentDefault
    }

    /// v1: returns the default preset for any bundleID. Slice 4 will introduce overrides.
    func preset(for bundleID: String?) -> Preset {
        _ = bundleID
        return defaultPreset()
    }

    /// Re-read `presets.json` and replace the in-memory default. On error the
    /// previous in-memory preset is retained and the error is rethrown so the
    /// caller can surface a notification.
    func reload() throws {
        let loaded = try Self.loadFromDisk(at: fileURL)
        lock.lock(); defer { lock.unlock() }
        currentDefault = loaded
    }

    // MARK: - Disk

    private static func ensureDirectory(for fileURL: URL) throws {
        let dir = fileURL.deletingLastPathComponent()
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        }
    }

    private static func writeBaselineFile(at url: URL) throws {
        let payload: [String: String] = ["default": defaultPromptTemplate]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: url.path
        )
    }

    private static func loadFromDisk(at url: URL) throws -> Preset {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PresetStoreError.fileUnreadable(error.localizedDescription)
        }

        // Tolerant decode: only require the `default` key. Unknown keys
        // (e.g., Slice 4's `overrides`) are ignored.
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw PresetStoreError.malformedJSON(error.localizedDescription)
        }

        guard
            let dict = object as? [String: Any],
            let defaultTemplate = dict["default"] as? String,
            !defaultTemplate.isEmpty
        else {
            throw PresetStoreError.missingDefaultKey
        }

        return Preset(name: "default", promptTemplate: defaultTemplate)
    }
}
