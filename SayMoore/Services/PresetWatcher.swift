import Foundation
import CoreServices

/// Watches a directory for changes to a single file and invokes `onChange` on
/// the calling queue when that file is created, modified, renamed, or removed.
///
/// Uses `FSEventStream` against the *parent* directory rather than the file
/// itself so atomic temp-rename writes (the way VSCode, Xcode, and most modern
/// editors save) are observed reliably — watching a file inode directly misses
/// these events because the new file gets a different inode.
final class PresetWatcher: @unchecked Sendable {
    private let directory: URL
    private let fileName: String
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "com.seemoretmoore.saymoore.preset-watcher")

    private var stream: FSEventStreamRef?
    private var started = false

    init(directory: URL, fileName: String, onChange: @escaping () -> Void) {
        self.directory = directory
        self.fileName = fileName
        self.onChange = onChange
    }

    deinit {
        teardown()
    }

    /// Arm the watcher. No-op if the directory does not exist (the caller is
    /// responsible for creating it first; FSEventStream cannot arm on a missing
    /// path). Safe to call multiple times.
    func start() {
        if started { return }

        var isDir: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir),
            isDir.boolValue
        else {
            Log.presets.error("PresetWatcher.start: directory missing at \(self.directory.path, privacy: .public)")
            return
        }

        let info = Unmanaged.passUnretained(self).toOpaque()
        var context = FSEventStreamContext(
            version: 0,
            info: info,
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { (_, clientInfo, numEvents, eventPaths, _, _) in
            guard let info = clientInfo else { return }
            let watcher = Unmanaged<PresetWatcher>.fromOpaque(info).takeUnretainedValue()
            guard let cfPaths = unsafeBitCast(eventPaths, to: CFArray.self) as? [String] else { return }
            for path in cfPaths.prefix(numEvents) {
                if (path as NSString).lastPathComponent == watcher.fileName {
                    watcher.onChange()
                    return
                }
            }
        }

        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagUseCFTypes
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1, // 100ms coalescing
            flags
        ) else {
            Log.presets.error("PresetWatcher.start: FSEventStreamCreate returned nil")
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        if !FSEventStreamStart(stream) {
            Log.presets.error("PresetWatcher.start: FSEventStreamStart failed")
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }

        self.stream = stream
        self.started = true
        Log.presets.info("PresetWatcher armed on \(self.directory.path, privacy: .public)")
    }

    /// Disarm and release the underlying stream. Safe to call multiple times.
    func stop() {
        teardown()
    }

    private func teardown() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        self.started = false
    }
}
