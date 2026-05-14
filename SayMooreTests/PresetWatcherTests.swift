import XCTest
@testable import SayMoore

final class PresetWatcherTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PresetWatcherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Resolve symlinks (FSEvents emits canonical paths; macOS /var → /private/var).
        tmpDir = base.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        if let dir = tmpDir { try? FileManager.default.removeItem(at: dir) }
    }

    func testAtomicRenameFiresOnChange() throws {
        let exp = expectation(description: "onChange fires")
        exp.assertForOverFulfill = false

        let watcher = PresetWatcher(directory: tmpDir, fileName: "presets.json") {
            exp.fulfill()
        }
        watcher.start()
        defer { watcher.stop() }

        // Give FSEvents a moment to arm before writing.
        Thread.sleep(forTimeInterval: 0.2)

        let url = tmpDir.appendingPathComponent("presets.json")
        try Data(#"{"default":"X"}"#.utf8).write(to: url, options: .atomic)

        wait(for: [exp], timeout: 3.0)
    }

    func testInPlaceWriteFiresOnChange() throws {
        let url = tmpDir.appendingPathComponent("presets.json")
        try Data(#"{"default":"X"}"#.utf8).write(to: url, options: .atomic)

        let exp = expectation(description: "onChange fires")
        exp.assertForOverFulfill = false

        let watcher = PresetWatcher(directory: tmpDir, fileName: "presets.json") {
            exp.fulfill()
        }
        watcher.start()
        defer { watcher.stop() }

        Thread.sleep(forTimeInterval: 0.2)

        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(#"{"default":"Y"}"#.utf8))
        try handle.close()

        wait(for: [exp], timeout: 3.0)
    }

    func testUnrelatedFileEventIgnored() throws {
        let exp = expectation(description: "onChange must NOT fire")
        exp.isInverted = true

        let watcher = PresetWatcher(directory: tmpDir, fileName: "presets.json") {
            exp.fulfill()
        }
        watcher.start()
        defer { watcher.stop() }

        Thread.sleep(forTimeInterval: 0.2)

        let url = tmpDir.appendingPathComponent("other.json")
        try Data(#"{}"#.utf8).write(to: url, options: .atomic)

        wait(for: [exp], timeout: 1.5)
    }

    func testStopDeactivatesWatcher() throws {
        let exp = expectation(description: "onChange must NOT fire after stop")
        exp.isInverted = true

        let watcher = PresetWatcher(directory: tmpDir, fileName: "presets.json") {
            exp.fulfill()
        }
        watcher.start()
        Thread.sleep(forTimeInterval: 0.2)
        watcher.stop()

        let url = tmpDir.appendingPathComponent("presets.json")
        try Data(#"{"default":"X"}"#.utf8).write(to: url, options: .atomic)

        wait(for: [exp], timeout: 1.5)
    }

    func testStartOnMissingDirectoryIsNoOp() {
        let missing = tmpDir.appendingPathComponent("does-not-exist", isDirectory: true)
        let watcher = PresetWatcher(directory: missing, fileName: "presets.json") {
            XCTFail("should not fire")
        }
        watcher.start()
        watcher.stop()
    }
}
