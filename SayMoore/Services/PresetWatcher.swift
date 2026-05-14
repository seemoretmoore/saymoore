import Foundation
import CoreServices

// Top-level @convention(c) retain/release thunks for FSEventStreamContext.
// These cannot be Swift closures with captures — the FSEvents API expects
// CFAllocatorRetainCallBack-shaped function pointers. Pairing these with
// `passUnretained(self).toOpaque()` lets FSEvents take its own +1 retain,
// guaranteeing the watcher outlives any in-flight callback.
private func presetWatcherRetain(_ info: UnsafeRawPointer?) -> UnsafeRawPointer? {
    guard let info else { return nil }
    _ = Unmanaged<PresetWatcher>.fromOpaque(info).retain()
    return info
}

private func presetWatcherRelease(_ info: UnsafeRawPointer?) {
    guard let info else { return }
    Unmanaged<PresetWatcher>.fromOpaque(info).release()
}

/// Watches a directory for changes to a single file and invokes `onChange`
/// when that file is created, modified, renamed, or removed.
///
/// Uses `FSEventStream` against the *parent* directory rather than the file
/// itself so atomic temp-rename writes (the way VSCode, BBEdit, and most
/// modern editors save) are observed reliably — watching a file inode
/// directly misses these events because the new file gets a different inode.
///
/// `onChange` runs on the watcher's private dispatch queue (not the caller's
/// queue). Hop to MainActor inside `onChange` if you need to touch UI state.
///
/// Thread-safety: `start`/`stop`/`teardown` and the FSEvents callback all
/// take `lock` before touching `stream` or `started`. FSEvents holds a +1
/// retain on `self` via the retain-callback in `FSEventStreamContext`, so the
/// instance is guaranteed to outlive any in-flight callback. `@unchecked
/// Sendable` is asserted because mutable state is guarded by the lock and the
/// FSEvents-side lifetime is owned by the +1 retain.
final class PresetWatcher: @unchecked Sendable {
    private let directory: URL
    private let fileName: String
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "com.seemoretmoore.saymoore.preset-watcher")
    private let lock = NSLock()

    private var stream: FSEventStreamRef?
    private var started = false

    init(directory: URL, fileName: String, onChange: @escaping () -> Void) {
        self.directory = directory
        self.fileName = fileName
        self.onChange = onChange
    }

    deinit {
        // No `queue.sync` here — would deadlock if deinit fires from inside
        // the FSEvents callback chain. FSEventStreamInvalidate joins pending
        // callbacks on the dispatch queue per Apple docs, and the matched
        // retain/release callbacks balance the +1 on `self`.
        teardown()
    }

    /// Arm the watcher. No-op if the directory does not exist (the caller is
    /// responsible for creating it first; FSEventStream cannot arm on a
    /// missing path). Safe to call multiple times.
    func start() {
        lock.lock()
        if started {
            lock.unlock()
            return
        }
        lock.unlock()

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
            retain: presetWatcherRetain,
            release: presetWatcherRelease,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { (_, clientInfo, numEvents, eventPaths, _, _) in
            guard let info = clientInfo else { return }
            let watcher = Unmanaged<PresetWatcher>.fromOpaque(info).takeUnretainedValue()

            // Re-check that we haven't been torn down. The +1 retain keeps the
            // instance alive, but `stream` is nilled under the lock during
            // teardown — that's our "stop processing" signal for any callback
            // that beat the FSEvents-side drain.
            watcher.lock.lock()
            let active = watcher.stream != nil
            watcher.lock.unlock()
            if !active { return }

            guard let cfPaths = unsafeBitCast(eventPaths, to: CFArray.self) as? [String] else { return }
            for path in cfPaths.prefix(numEvents) {
                if URL(fileURLWithPath: path).lastPathComponent == watcher.fileName {
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

        lock.lock()
        self.stream = stream
        self.started = true
        lock.unlock()
        Log.presets.info("PresetWatcher armed on \(self.directory.path, privacy: .public)")
    }

    /// Disarm and release the underlying stream. Safe to call multiple times.
    func stop() {
        teardown()
    }

    private func teardown() {
        // Capture and clear under the lock, then act on the snapshot outside.
        // Doing the actual FSEvents API calls outside the lock avoids
        // deadlocking against a callback that's currently waiting on the
        // same lock (the callback's lock acquisition is short, but defensive).
        lock.lock()
        let s = stream
        stream = nil
        started = false
        lock.unlock()

        guard let s else { return }
        FSEventStreamStop(s)
        FSEventStreamSetDispatchQueue(s, nil)
        FSEventStreamInvalidate(s)  // Drains pending callbacks on the queue; triggers release callback.
        FSEventStreamRelease(s)     // Drops our local reference.
    }
}
