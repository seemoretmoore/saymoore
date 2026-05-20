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

extension HistoryStoreTests {
    private func makeEntry(_ i: Int) -> HistoryEntry {
        HistoryEntry(
            schemaVersion: HistoryEntry.currentSchemaVersion,
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: TimeInterval(1_716_000_000 + i)),
            durationSeconds: 1.0,
            rawTranscript: "entry \(i)",
            cleanedTranscript: "Entry \(i).",
            bundleID: nil,
            wordCount: 2
        )
    }

    private func makeTempStore() throws -> (HistoryStore, URL) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("HistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        let store = try HistoryStore(directory: tmp, fileName: "history.jsonl")
        return (store, tmp)
    }

    func test_append_cappedAt50_evictsOldest() async throws {
        let (store, tmp) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        for i in 0..<60 {
            try await store.append(makeEntry(i))
        }

        let all = try await store.loadAll()
        XCTAssertEqual(all.count, 50)
        XCTAssertEqual(all.first?.rawTranscript, "entry 10")
        XCTAssertEqual(all.last?.rawTranscript, "entry 59")
    }
}
