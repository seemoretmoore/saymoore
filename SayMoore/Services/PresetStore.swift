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
    private var currentOverrides: [String: Preset] = [:]

    /// Production initializer. Ensures the preset directory exists, materializes
    /// `presets.json` from the bundled example (or hardcoded baseline as fallback)
    /// on first launch, and loads the on-disk default + overrides. Load errors
    /// fall back to the hardcoded baseline.
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
                try? Self.materializeBaseline(at: fileURL)
            }
        }

        if let loaded = try? Self.loadFromDisk(at: fileURL) {
            self.currentDefault = loaded.defaultPreset
            self.currentOverrides = loaded.overrides
        }
    }

    func defaultPreset() -> Preset {
        lock.lock(); defer { lock.unlock() }
        return currentDefault
    }

    /// Resolve a preset for the given bundle ID. Falls back to the default when
    /// `bundleID` is nil or has no override entry.
    func preset(for bundleID: String?) -> Preset {
        lock.lock(); defer { lock.unlock() }
        if let id = bundleID, let override = currentOverrides[id] {
            return override
        }
        return currentDefault
    }

    /// Re-read `presets.json` and atomically replace the in-memory default +
    /// overrides. On error the previous in-memory state is retained and the
    /// error is rethrown so the caller can surface a notification.
    func reload() throws {
        let loaded = try Self.loadFromDisk(at: fileURL)
        lock.lock(); defer { lock.unlock() }
        currentDefault = loaded.defaultPreset
        currentOverrides = loaded.overrides
    }

    // MARK: - Disk

    private struct LoadedPresets {
        let defaultPreset: Preset
        let overrides: [String: Preset]
    }

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

    /// Seed `presets.json` on first launch. Prefers the bundled
    /// `presets.example.json` (ships with 5 per-app overrides); falls back to a
    /// hardcoded default-only payload when the bundle resource is unavailable
    /// (tests, command-line contexts).
    private static func materializeBaseline(at url: URL) throws {
        if let bundled = Bundle.main.url(forResource: "presets.example", withExtension: "json"),
           let data = try? Data(contentsOf: bundled) {
            try data.write(to: url, options: .atomic)
        } else {
            let payload: [String: String] = ["default": defaultPromptTemplate]
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(payload)
            try data.write(to: url, options: .atomic)
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: url.path
        )
    }

    private static func loadFromDisk(at url: URL) throws -> LoadedPresets {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PresetStoreError.fileUnreadable(error.localizedDescription)
        }

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

        var overrides: [String: Preset] = [:]
        if let rawOverrides = dict["overrides"] as? [String: Any] {
            for (bundleID, value) in rawOverrides {
                guard let template = value as? String, !template.isEmpty else { continue }
                overrides[bundleID] = Preset(name: bundleID, promptTemplate: template)
            }
        }

        return LoadedPresets(
            defaultPreset: Preset(name: "default", promptTemplate: defaultTemplate),
            overrides: overrides
        )
    }
}
