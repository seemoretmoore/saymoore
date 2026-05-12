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
