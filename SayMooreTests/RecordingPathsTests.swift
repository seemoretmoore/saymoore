import XCTest
@testable import SayMoore

final class RecordingPathsTests: XCTestCase {
    func testEnsuresDirectoryWithMode0700() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("saymoore-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let dir = try RecordingPaths.ensureDirectory(at: tmp)
        XCTAssertEqual(dir, tmp)

        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)

        let attrs = try FileManager.default.attributesOfItem(atPath: tmp.path)
        let perms = attrs[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o700)
    }

    func testPurgeAllRemovesEveryFile() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("saymoore-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try RecordingPaths.ensureDirectory(at: tmp)

        let a = tmp.appendingPathComponent("a.wav")
        let b = tmp.appendingPathComponent("b.wav")
        try Data([0x42]).write(to: a)
        try Data([0x42]).write(to: b)

        RecordingPaths.purgeAll(in: tmp)

        let contents = try FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)
        XCTAssertEqual(contents.count, 0)
        // Directory itself still exists.
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func testPurgeAllIsNoOpWhenDirectoryMissing() {
        let bogus = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("saymoore-nonexistent-\(UUID().uuidString)", isDirectory: true)
        // Should not crash.
        RecordingPaths.purgeAll(in: bogus)
    }

    func testGeneratesUniqueWavURLs() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("saymoore-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try RecordingPaths.ensureDirectory(at: tmp)

        let a = RecordingPaths.newRecordingURL(in: tmp)
        let b = RecordingPaths.newRecordingURL(in: tmp)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.pathExtension, "wav")
        XCTAssertTrue(a.path.hasPrefix(tmp.path))
    }
}
