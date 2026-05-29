import Foundation
import SwiftUI

/// v1.1 Settings window view model. Bridges SwiftUI bindings into the
/// existing PresetStore + UserDefaults surfaces. JSON-on-disk stays the
/// source of truth — every write here goes through `PresetStore.setVocabulary`
/// and is then re-read by the existing FSEvents watcher, so settings + a
/// hand-edited file converge to the same state.
@MainActor
final class SettingsViewModel: ObservableObject {
    let presets: PresetStore
    /// Live vocabulary editing buffer. Reads from PresetStore on init and
    /// after each reload; writes go through `commitVocabulary`.
    @Published var vocab: [VocabRow] = []
    @Published var muted: Bool {
        didSet {
            UserDefaults.standard.set(muted, forKey: "audio.feedback.muted")
        }
    }
    @Published var streamingMode: StreamingMode {
        didSet {
            UserDefaults.standard.set(streamingMode.rawValue, forKey: StreamingMode.userDefaultsKey)
        }
    }
    @Published var lastError: String?

    /// Row identity used by the SwiftUI table. We keep a `UUID` so the
    /// editor can reorder / delete by index without remounting every row.
    struct VocabRow: Identifiable, Equatable {
        let id: UUID
        var phonetic: String
        var canonical: String
        init(id: UUID = UUID(), phonetic: String, canonical: String) {
            self.id = id
            self.phonetic = phonetic
            self.canonical = canonical
        }
        static func from(_ e: VocabEntry) -> VocabRow {
            VocabRow(phonetic: e.phonetic, canonical: e.canonical)
        }
        var entry: VocabEntry { VocabEntry(phonetic: phonetic, canonical: canonical) }
    }

    init(presets: PresetStore) {
        self.presets = presets
        self.muted = UserDefaults.standard.bool(forKey: "audio.feedback.muted")
        let raw = UserDefaults.standard.string(forKey: StreamingMode.userDefaultsKey)
        self.streamingMode = raw.flatMap(StreamingMode.init(rawValue:)) ?? .default
        refresh()
    }

    /// Re-pull state from PresetStore. Called on Settings window show and
    /// after FSEvents-driven reloads (so a hand-edit of presets.json is
    /// reflected in the UI without requiring the user to switch tabs).
    /// Preserves row UUIDs across refresh when the (phonetic, canonical)
    /// pair survives — that keeps TextField focus + selection stable for
    /// the user during external edits.
    func refresh() {
        let current = presets.vocabulary()
        let lookup = Dictionary(
            uniqueKeysWithValues: vocab.map { (Self.key(phonetic: $0.phonetic, canonical: $0.canonical), $0.id) }
        )
        self.vocab = current.map { entry in
            let k = Self.key(phonetic: entry.phonetic, canonical: entry.canonical)
            if let existing = lookup[k] {
                return VocabRow(id: existing, phonetic: entry.phonetic, canonical: entry.canonical)
            }
            return VocabRow.from(entry)
        }
    }

    private static func key(phonetic: String, canonical: String) -> String {
        "\(phonetic)\u{1F}\(canonical)" // unit separator avoids accidental collision
    }

    func addVocabRow() {
        vocab.append(VocabRow(phonetic: "", canonical: ""))
        lastError = nil
    }

    func removeVocabRow(_ row: VocabRow) {
        vocab.removeAll { $0.id == row.id }
        lastError = nil
    }

    /// Drop empty rows, write to disk. Returns true on success.
    /// On failure, `lastError` is set and the on-disk file is unchanged.
    /// Does NOT call `refresh()` — the in-memory `vocab` is authoritative
    /// post-save (refresh-from-disk would rotate row UUIDs unnecessarily
    /// and break focus / selection).
    @discardableResult
    func commitVocabulary() -> Bool {
        let cleaned = vocab.compactMap { row -> VocabEntry? in
            let p = row.phonetic.trimmingCharacters(in: .whitespacesAndNewlines)
            let c = row.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
            if p.isEmpty || c.isEmpty { return nil }
            return VocabEntry(phonetic: p, canonical: c)
        }
        do {
            try presets.setVocabulary(cleaned)
            lastError = nil
            return true
        } catch let e as PresetStoreError {
            lastError = friendlyError(e)
            return false
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    private func friendlyError(_ e: PresetStoreError) -> String {
        switch e {
        case .tooManyVocabEntries: return "Too many vocabulary entries (max \(PresetStore.maxVocabularyEntries))."
        case .vocabEntryTooLong: return "A vocabulary entry is too long (max \(PresetStore.maxVocabularyEntryBytes) bytes per side)."
        case .vocabularyTooLarge: return "Vocabulary is too large overall (max \(PresetStore.maxVocabularyTotalBytes) bytes)."
        default: return String(describing: e)
        }
    }

    var bundleShortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    var bundleBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }
}
