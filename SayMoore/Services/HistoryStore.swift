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
}
