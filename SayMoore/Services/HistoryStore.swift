import Foundation

struct HistoryEntry: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: UUID
    let timestamp: Date
    let durationSeconds: Double
    let rawTranscript: String
    let cleanedTranscript: String?
    let bundleID: String?
    let wordCount: Int
}

enum HistoryStoreSupport {
    static let maxEntries = 50
}

actor HistoryStore {
    private let directory: URL
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(directory: URL, fileName: String = "history.jsonl") throws {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent(fileName, isDirectory: false)
        self.encoder = HistoryStore.makeEncoder()
        self.decoder = HistoryStore.makeDecoder()
        try ensureDirectory()
    }

    func append(_ entry: HistoryEntry) throws {
        var entries = try loadAllSync()
        entries.append(entry)
        if entries.count > HistoryStoreSupport.maxEntries {
            entries.removeFirst(entries.count - HistoryStoreSupport.maxEntries)
        }
        try writeAtomically(entries)
    }

    func loadAll() throws -> [HistoryEntry] {
        try loadAllSync()
    }

    var debugLogURL: URL { fileURL }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - Internals

    private func loadAllSync() throws -> [HistoryEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return [] }
        var out: [HistoryEntry] = []
        out.reserveCapacity(HistoryStoreSupport.maxEntries)
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            let lineData = Data(line)
            let entry = try decoder.decode(HistoryEntry.self, from: lineData)
            out.append(entry)
        }
        return out
    }

    nonisolated private func ensureDirectory() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        } else {
            try fm.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: directory.path
            )
        }
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    private func writeAtomically(_ entries: [HistoryEntry]) throws {
        var blob = Data()
        for entry in entries {
            let line = try encoder.encode(entry)
            blob.append(line)
            blob.append(0x0A)
        }
        let tmpURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        try blob.write(to: tmpURL, options: .atomic)
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) {
            _ = try fm.replaceItemAt(fileURL, withItemAt: tmpURL)
        } else {
            try fm.moveItem(at: tmpURL, to: fileURL)
        }
        try fm.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: fileURL.path
        )
    }
}
