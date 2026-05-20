# Slice 7 — History Log Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Append every successful dictation to a hardened, rolling 50-entry JSONL history log and surface it from the menu bar as "Open Debug Log in Finder".

**Architecture:** New `HistoryStore` actor owns a single JSONL file at `~/Library/Application Support/SayMoore/History.noindex/history.jsonl`. Atomic full-rewrite on append (read → append → trim to 50 → write to `.tmp` → `replaceItemAt`). Actor serializes all writers. `PipelineCoordinator.processSamples` calls `append` after a successful paste. `MenuBarController` gains a single menu item that reveals the file in Finder.

**Tech Stack:** Swift 5+, Foundation, AppKit, XCTest, XcodeGen.

**Naming convention:** v1 framing is "Debug Log" (menu item label) — sets user expectations that this is for troubleshooting, not a polished review surface. Internal types are still `HistoryEntry` / `HistoryStore`.

---

## File Structure

**Create:**
- `SayMoore/Services/HistoryStore.swift` — actor + `HistoryEntry` codable struct + path helpers
- `SayMooreTests/HistoryStoreTests.swift` — unit tests (serialization roundtrip, cap eviction, concurrent append, filesystem hardening)
- `docs/manual-tests/slice-7.md` — manual test matrix + sign-off

**Modify:**
- `SayMoore/App/AppDelegate.swift` — instantiate `HistoryStore`, inject into `PipelineCoordinator`, pass to `MenuBarController`
- `SayMoore/App/PipelineCoordinator.swift` — accept `HistoryStore` in init, call `append(...)` after successful paste in `processSamples`
- `SayMoore/UI/MenuBarController.swift` — accept `HistoryStore`, add "Open Debug Log in Finder" menu item + `@objc` handler

**Regenerate:**
- Run `bash scripts/generate-project.sh` after creating new Swift files (xcodeproj is gitignored).

---

## Data Model

```swift
struct HistoryEntry: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: UUID
    let timestamp: Date
    let durationSeconds: Double
    let rawTranscript: String
    let cleanedTranscript: String?   // nil if cleanup skipped/failed
    let bundleID: String?            // captured frontmost app at recording start
    let wordCount: Int               // of cleanedTranscript ?? rawTranscript
}
```

JSONL encoding: one `HistoryEntry` per line, UTF-8, `\n` separator, no trailing newline on final line beyond the per-record one. Dates encoded as ISO8601 with fractional seconds.

---

## Task 1: HistoryEntry Codable model + roundtrip test

**Files:**
- Create: `SayMoore/Services/HistoryStore.swift`
- Test: `SayMooreTests/HistoryStoreTests.swift`

- [ ] **Step 1: Write the failing roundtrip test**

Create `SayMooreTests/HistoryStoreTests.swift`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild -project SayMoore.xcodeproj -scheme SayMoore -destination 'platform=macOS' \
  -only-testing:SayMooreTests/HistoryStoreTests test
```

Expected: FAIL — `HistoryEntry` and `HistoryStore` undefined.

- [ ] **Step 3: Create `HistoryStore.swift` with model + encoder/decoder factories**

Create `SayMoore/Services/HistoryStore.swift`:

```swift
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
```

- [ ] **Step 4: Regenerate xcodeproj and run test to verify it passes**

Run:
```bash
bash scripts/generate-project.sh
xcodebuild -project SayMoore.xcodeproj -scheme SayMoore -destination 'platform=macOS' \
  -only-testing:SayMooreTests/HistoryStoreTests/test_historyEntry_codable_roundtrip test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add SayMoore/Services/HistoryStore.swift SayMooreTests/HistoryStoreTests.swift
git commit -m "feat(slice-7): HistoryEntry codable model + roundtrip test"
```

---

## Task 2: HistoryStore.append with 50-entry rolling cap (no filesystem hardening yet)

**Files:**
- Modify: `SayMoore/Services/HistoryStore.swift`
- Test: `SayMooreTests/HistoryStoreTests.swift`

- [ ] **Step 1: Write the failing cap-eviction test**

Append to `SayMooreTests/HistoryStoreTests.swift`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild -project SayMoore.xcodeproj -scheme SayMoore -destination 'platform=macOS' \
  -only-testing:SayMooreTests/HistoryStoreTests/test_append_cappedAt50_evictsOldest test
```

Expected: FAIL — `HistoryStore.init(directory:fileName:)`, `append`, `loadAll` undefined.

- [ ] **Step 3: Implement `init`, `append`, `loadAll`**

Replace the `actor HistoryStore { ... }` block in `SayMoore/Services/HistoryStore.swift`:

```swift
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
        try ensureDirectory()
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

    // MARK: - Internals

    private func ensureDirectory() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        }
    }

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
    }
}
```

- [ ] **Step 4: Run cap-eviction test, expect pass**

Run:
```bash
xcodebuild -project SayMoore.xcodeproj -scheme SayMoore -destination 'platform=macOS' \
  -only-testing:SayMooreTests/HistoryStoreTests/test_append_cappedAt50_evictsOldest test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add SayMoore/Services/HistoryStore.swift SayMooreTests/HistoryStoreTests.swift
git commit -m "feat(slice-7): HistoryStore append with 50-entry rolling cap"
```

---

## Task 3: Filesystem hardening (0700 dir, 0600 file, .noindex, isExcludedFromBackup)

**Files:**
- Modify: `SayMoore/Services/HistoryStore.swift`
- Test: `SayMooreTests/HistoryStoreTests.swift`

- [ ] **Step 1: Write the failing hardening test**

Append to `SayMooreTests/HistoryStoreTests.swift`:

```swift
extension HistoryStoreTests {
    func test_init_setsDirectoryMode0700_andExcludesFromBackup() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("HistoryStoreTests-\(UUID().uuidString).noindex", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try HistoryStore(directory: tmp, fileName: "history.jsonl")

        let attrs = try FileManager.default.attributesOfItem(atPath: tmp.path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        XCTAssertEqual(mode & 0o777, 0o700, "directory should be mode 0700")

        var checkedURL = tmp
        let values = try checkedURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func test_append_setsFileMode0600() async throws {
        let (store, tmp) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try await store.append(makeEntry(0))

        let fileURL = tmp.appendingPathComponent("history.jsonl")
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        XCTAssertEqual(mode & 0o777, 0o600, "file should be mode 0600")
    }
}
```

- [ ] **Step 2: Run hardening tests to verify they fail**

Run:
```bash
xcodebuild -project SayMoore.xcodeproj -scheme SayMoore -destination 'platform=macOS' \
  -only-testing:SayMooreTests/HistoryStoreTests/test_init_setsDirectoryMode0700_andExcludesFromBackup \
  -only-testing:SayMooreTests/HistoryStoreTests/test_append_setsFileMode0600 test
```

Expected: both FAIL.

- [ ] **Step 3: Add hardening to `ensureDirectory` and `writeAtomically`**

In `SayMoore/Services/HistoryStore.swift`, replace `ensureDirectory()` and `writeAtomically(_:)`:

```swift
    private func ensureDirectory() throws {
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
```

- [ ] **Step 4: Run hardening tests, expect pass**

Run:
```bash
xcodebuild -project SayMoore.xcodeproj -scheme SayMoore -destination 'platform=macOS' \
  -only-testing:SayMooreTests/HistoryStoreTests/test_init_setsDirectoryMode0700_andExcludesFromBackup \
  -only-testing:SayMooreTests/HistoryStoreTests/test_append_setsFileMode0600 test
```

Expected: both PASS.

- [ ] **Step 5: Commit**

```bash
git add SayMoore/Services/HistoryStore.swift SayMooreTests/HistoryStoreTests.swift
git commit -m "feat(slice-7): harden history dir (0700+noindex+nobackup) and file (0600)"
```

---

## Task 4: Concurrent-append safety test

**Files:**
- Test: `SayMooreTests/HistoryStoreTests.swift`

- [ ] **Step 1: Write the failing concurrency test**

Append to `SayMooreTests/HistoryStoreTests.swift`:

```swift
extension HistoryStoreTests {
    func test_concurrentAppends_noLoss_noCorruption() async throws {
        let (store, tmp) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let writers = 20
        let perWriter = 5  // total 100, will cap at 50

        await withTaskGroup(of: Void.self) { group in
            for w in 0..<writers {
                group.addTask {
                    for j in 0..<perWriter {
                        let entry = HistoryEntry(
                            schemaVersion: HistoryEntry.currentSchemaVersion,
                            id: UUID(),
                            timestamp: Date(),
                            durationSeconds: 0.1,
                            rawTranscript: "w\(w)-j\(j)",
                            cleanedTranscript: nil,
                            bundleID: nil,
                            wordCount: 0
                        )
                        try? await store.append(entry)
                    }
                }
            }
        }

        let entries = try await store.loadAll()
        XCTAssertEqual(entries.count, HistoryStoreSupport.maxEntries,
                       "should reach the cap exactly with no corruption / no lost lines")
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count,
                       "all retained entries should be unique")
    }
}
```

- [ ] **Step 2: Run test, expect pass (actor already serializes)**

Run:
```bash
xcodebuild -project SayMoore.xcodeproj -scheme SayMoore -destination 'platform=macOS' \
  -only-testing:SayMooreTests/HistoryStoreTests/test_concurrentAppends_noLoss_noCorruption test
```

Expected: PASS. (The `actor` keyword serializes; this test proves it under load.)

If it fails, the fix is to audit `append` for non-actor escapes — do not introduce additional locks.

- [ ] **Step 3: Commit**

```bash
git add SayMooreTests/HistoryStoreTests.swift
git commit -m "test(slice-7): concurrent HistoryStore.append safety"
```

---

## Task 5: Production path helper + AppDelegate wiring

**Files:**
- Modify: `SayMoore/Services/HistoryStore.swift`
- Modify: `SayMoore/App/AppDelegate.swift`

- [ ] **Step 1: Add `HistoryStore.defaultDirectory()` static helper**

Append inside the `actor HistoryStore` body in `SayMoore/Services/HistoryStore.swift`:

```swift
    /// Resolves `~/Library/Application Support/SayMoore/History.noindex/` via FileManager.
    /// `.noindex` suffix prevents Spotlight from indexing transcripts.
    static func defaultDirectory() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport
            .appendingPathComponent("SayMoore", isDirectory: true)
            .appendingPathComponent("History.noindex", isDirectory: true)
    }
```

- [ ] **Step 2: Wire HistoryStore into AppDelegate**

In `SayMoore/App/AppDelegate.swift`, add a property next to the other lazy services (where `presets`, `paste`, etc. are declared):

```swift
    private lazy var historyStore: HistoryStore? = {
        do {
            let dir = try HistoryStore.defaultDirectory()
            return try HistoryStore(directory: dir)
        } catch {
            Logging.app.error("HistoryStore init failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }()
```

(Replace `Logging.app` if the project uses a different logger handle — check `SayMoore/Core/Logging.swift` for the actual logger name.)

In the `PipelineCoordinator(...)` constructor call (around lines 289–307), add `historyStore: historyStore` as a parameter — the exact placement is locked in Task 6. Leave a `// TODO(slice-7): inject` comment for now if the param isn't there yet:

```swift
        let coord = PipelineCoordinator(
            appState: appState,
            recorder: recorder,
            transcription: svc,
            paste: paste,
            presets: presets,
            cleanup: cleanup,
            recordingsDir: Self.recordingsDirIfPossible(),
            vadService: vadService,
            historyStore: historyStore,
            onFallback: { error in NotificationCoordinator.shared.notify(error) }
        )
```

- [ ] **Step 3: Build to confirm it compiles (PipelineCoordinator init signature change comes in Task 6)**

If `PipelineCoordinator` does not yet accept `historyStore`, this will fail to build — that's expected. Skip the build check here and proceed; Task 6 will make it compile.

If you want a green checkpoint first, comment the `historyStore: historyStore,` line out and uncomment it in Task 6.

- [ ] **Step 4: Commit (intermediate, may not build)**

```bash
git add SayMoore/Services/HistoryStore.swift SayMoore/App/AppDelegate.swift
git commit -m "feat(slice-7): defaultDirectory helper + AppDelegate wiring"
```

---

## Task 6: PipelineCoordinator integration

**Files:**
- Modify: `SayMoore/App/PipelineCoordinator.swift`

- [ ] **Step 1: Add `historyStore` to the initializer**

In `SayMoore/App/PipelineCoordinator.swift`, add a stored property near the other dependencies (around line 22 where `presets` lives):

```swift
    private let historyStore: HistoryStore?
```

Add `historyStore: HistoryStore?` to the designated initializer signature and assign in the body. If there's a convenience initializer with defaults, give it `historyStore: HistoryStore? = nil` so existing tests don't break.

- [ ] **Step 2: Call `historyStore?.append(...)` after successful paste**

In `processSamples(_ samples: [Float])`, between the existing successful paste (line 189) and `capturedBundleID = nil` (line 201), insert:

```swift
            let duration = Double(samples.count) / 16_000.0
            let chosenText = cleaned.isEmpty ? transcript.text : cleaned
            let wordCount = chosenText
                .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
                .count
            let entry = HistoryEntry(
                schemaVersion: HistoryEntry.currentSchemaVersion,
                id: UUID(),
                timestamp: Date(),
                durationSeconds: duration,
                rawTranscript: transcript.text,
                cleanedTranscript: cleaned == transcript.text ? nil : cleaned,
                bundleID: capturedBundleID,
                wordCount: wordCount
            )
            do {
                try await historyStore?.append(entry)
            } catch {
                Logging.app.error("history append failed: \(error.localizedDescription, privacy: .public)")
            }
```

(Use the same logger handle that exists elsewhere in this file — adjust `Logging.app` to match.)

Rationale notes (do not embed as code comments — they live here):
- History-append failure must not surface a banner or block the success path; the user already got their paste.
- `cleanedTranscript` is stored as `nil` when cleanup was skipped or returned the raw text unchanged, so consumers can tell "no cleaning happened" from "cleaning produced identical output as a string".

- [ ] **Step 3: Build the app**

Run:
```bash
xcodebuild -project SayMoore.xcodeproj -scheme SayMoore -destination 'platform=macOS' build
```

Expected: SUCCESS. Fix any test-target call sites that use the old `PipelineCoordinator` initializer by passing `historyStore: nil`.

- [ ] **Step 4: Run the full test suite**

Run:
```bash
xcodebuild -project SayMoore.xcodeproj -scheme SayMoore -destination 'platform=macOS' test
```

Expected: all tests pass (215+ existing + 4 new).

- [ ] **Step 5: Commit**

```bash
git add SayMoore/App/PipelineCoordinator.swift SayMoore/App/AppDelegate.swift
git commit -m "feat(slice-7): wire HistoryStore.append into PipelineCoordinator success path"
```

---

## Task 7: MenuBarController "Open Debug Log in Finder" item

**Files:**
- Modify: `SayMoore/UI/MenuBarController.swift`
- Modify: `SayMoore/App/AppDelegate.swift`

- [ ] **Step 1: Accept `HistoryStore` in MenuBarController**

In `SayMoore/UI/MenuBarController.swift`, add a stored property near the other deps:

```swift
    private let historyStore: HistoryStore?
```

Update the initializer signature to accept `historyStore: HistoryStore?` and assign in the body.

- [ ] **Step 2: Add the menu item**

Inside the `init(...)`, after the existing `reloadItem`/edit-presets items (the explore agent flagged "after line 51" — the spot just before the final separator), add:

```swift
        let debugLogItem = NSMenuItem(
            title: "Open Debug Log in Finder",
            action: #selector(openDebugLogTapped),
            keyEquivalent: ""
        )
        debugLogItem.target = self
        menu.addItem(NSMenuItem.separator())
        menu.addItem(debugLogItem)
```

- [ ] **Step 3: Add the `@objc` handler**

Next to the existing `@objc private func editPresetsTapped()` / `@objc private func reloadPresetsTapped()`:

```swift
    @objc private func openDebugLogTapped() {
        guard let store = historyStore else {
            NSSound.beep()
            return
        }
        Task { @MainActor in
            let url = await store.debugLogURL
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                // File hasn't been created yet — reveal the parent .noindex dir instead.
                NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
            }
        }
    }
```

- [ ] **Step 4: Update AppDelegate to pass `historyStore` into MenuBarController**

In `SayMoore/App/AppDelegate.swift`, find the `MenuBarController(...)` construction and add `historyStore: historyStore` to its arg list.

- [ ] **Step 5: Build + run the app**

```bash
xcodebuild -project SayMoore.xcodeproj -scheme SayMoore -destination 'platform=macOS' build
bash scripts/install-debug.sh
open ~/Applications/SayMoore.app
```

Click the menu bar icon, confirm "Open Debug Log in Finder" is present, click it — Finder opens with either `history.jsonl` selected (if dictations have already happened) or the parent `History.noindex` directory (first run).

- [ ] **Step 6: Run tests once more to confirm no regression**

```bash
xcodebuild -project SayMoore.xcodeproj -scheme SayMoore -destination 'platform=macOS' test
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add SayMoore/UI/MenuBarController.swift SayMoore/App/AppDelegate.swift
git commit -m "feat(slice-7): add Open Debug Log in Finder menu item"
```

---

## Task 8: Manual test matrix + sign-off

**Files:**
- Create: `docs/manual-tests/slice-7.md`

- [ ] **Step 1: Author the test matrix**

Create `docs/manual-tests/slice-7.md`:

```markdown
# Slice 7 — History Log: Manual Test Matrix

Branch: `feat/slice-7-history-log`  HEAD: `<fill in after merge>`

## Pre-flight
- Build Debug, install via `scripts/install-debug.sh`, launch `~/Applications/SayMoore.app`.
- Confirm app support dir is clean OR back up `~/Library/Application Support/SayMoore/History.noindex/history.jsonl` if it exists.

## T1 — First dictation creates dir + file
- Dictate one phrase, confirm paste lands.
- Verify `~/Library/Application Support/SayMoore/History.noindex/` exists.
- `stat -f '%Sp %N' ~/Library/Application\ Support/SayMoore/History.noindex` should show `drwx------`.
- `stat -f '%Sp %N' ~/Library/Application\ Support/SayMoore/History.noindex/history.jsonl` should show `-rw-------`.
- `xattr -p com.apple.metadata:com_apple_backup_excludeItem ~/Library/Application\ Support/SayMoore/History.noindex` should print the backup-exclude value (or the URLResourceKey equivalent is set — verify via `mdls` or Finder's "Locked"/"Excluded" indicator).
- File has exactly 1 line of valid JSON; schema fields present.

## T2 — Rolling cap at 50
- Dictate 60 short phrases (counting on screen helps).
- `wc -l ~/Library/Application\ Support/SayMoore/History.noindex/history.jsonl` should print `50`.
- The first surviving entry's `rawTranscript` should be from the 11th dictation, not the 1st.

## T3 — Menu item reveals the file
- Click menu bar icon → "Open Debug Log in Finder".
- Finder opens with `history.jsonl` selected.

## T4 — Spotlight exclusion
- `mdfind -name history.jsonl` should NOT list the file (because of `.noindex` suffix on the parent dir).

## T5 — Concurrent dictation isn't possible (single hotkey), but force-pressure with rapid back-to-back
- Dictate 5 phrases as fast as possible (Ctrl-Ctrl, speak, Ctrl-Ctrl).
- `wc -l history.jsonl` increments by 5 with no malformed lines (each `jq -c .` parses).

## T6 — Cleanup-failed path still appends
- Quit Ollama (menu-bar icon → Quit). Dictate once. Confirm raw transcript is pasted (fallback). Confirm `history.jsonl` last line has `"cleanedTranscript": null` and `rawTranscript` populated.

## T7 — Reveal-dir fallback when file doesn't exist
- `rm history.jsonl`. Open menu → "Open Debug Log in Finder". Finder should reveal the `History.noindex` directory (file missing → parent fallback).

## Sign-off
- [ ] All T1–T7 pass on commit `<sha>`.
```

- [ ] **Step 2: Commit**

```bash
git add docs/manual-tests/slice-7.md
git commit -m "docs(slice-7): manual test matrix for history log"
```

---

## Verification — end-to-end

After all tasks:

1. **Automated:** `xcodebuild -project SayMoore.xcodeproj -scheme SayMoore -destination 'platform=macOS' test` — full suite green.
2. **Manual:** Walk through `docs/manual-tests/slice-7.md` T1–T7, check off each box.
3. **Daily-use launch path:** `bash scripts/install-debug.sh && open ~/Applications/SayMoore.app`. Dictate, click menu, confirm Finder reveals the file. (Per project memory: never launch from DerivedData.)

## Critical files

- `SayMoore/Services/HistoryStore.swift` (new)
- `SayMoore/App/PipelineCoordinator.swift` (init signature + `processSamples` body)
- `SayMoore/App/AppDelegate.swift` (lazy instantiation + dependency wiring)
- `SayMoore/UI/MenuBarController.swift` (init signature + menu item + handler)
- `SayMooreTests/HistoryStoreTests.swift` (new)
- `docs/manual-tests/slice-7.md` (new)

## Reused existing utilities

- `FileManager.url(for: .applicationSupportDirectory, ...)` — matches the project rule "no hard-coded `~/...` strings".
- `URLResourceValues.isExcludedFromBackup` — Foundation API.
- `NSWorkspace.shared.activateFileViewerSelecting([url])` — already used elsewhere; standard reveal-in-Finder pattern.
- `Logging.*` — existing OSLog facade in `SayMoore/Core/Logging.swift`. Use whatever handle the surrounding file already uses.

## Out of scope (explicitly NOT this slice)

- History viewer UI. v1 is "Open Debug Log in Finder", framing the file as debug output.
- Schema migrations. v1 ships schema version 1 only; v2 will gain a migration path.
- Per-entry redaction or filtering. Sensitive data lives in `History.noindex` and is excluded from Spotlight + backup; that's the v1 protection.
- Export / share / clear-all menu actions. Defer until a real history surface ships.
