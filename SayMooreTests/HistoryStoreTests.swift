import XCTest
@testable import SayMoore

final class HistoryStoreTests: XCTestCase {
    func test_historyEntry_codable_roundtrip() throws {
        let original = HistoryEntry(
            schemaVersion: HistoryEntry.currentSchemaVersion,
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_716_000_000),
            durationSeconds: 4.25,
            rawTranscript: "hello world",
            cleanedTranscript: "Hello world.",
            bundleID: "com.tinyspeck.slackmacgap",
            wordCount: 2
        )

        let encoder = HistoryStore.makeEncoder()
        let decoder = HistoryStore.makeDecoder()

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(HistoryEntry.self, from: data)

        XCTAssertEqual(decoded, original)
    }
}
