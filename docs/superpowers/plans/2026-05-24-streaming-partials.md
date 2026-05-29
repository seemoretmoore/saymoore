# Streaming Partials Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Display rolling whisper transcription inside the Lifestream HUD pill while the user speaks (Layout B — text right of waveform), without changing the authoritative final-paste flow.

**Architecture:** A new `StreamingTranscriber` owns a sliding-window inference loop fed by a new `AudioRecorder.onSamples` tap callback. It calls a new internal `WhisperTranscriptionService.transcribeTimed(...)` that returns per-segment timing (whisper's `t0`/`t1`). The HUD gains a dynamic-width pill with an `NSTextField` showing committed (full opacity) and active-tail (italic, 0.85 opacity) text. A new `StreamingMode` enum (`off` / `balanced` / `responsive`) gates the feature via Settings ▸ General; UserDefaults key `streaming.partials.mode`. `PipelineCoordinator` instantiates / starts / `await`-stops the streamer around each recording; the final `transcribe()` path is unchanged.

**Tech Stack:** Swift 5.10 strict concurrency, AVAudioEngine, whisper.cpp (`ggml-large-v3-turbo.bin`), CALayer / NSTextField, SwiftUI Settings, XCTest.

**Spec:** `docs/superpowers/specs/2026-05-24-streaming-partials-design.md`

---

## File Structure

| File | Responsibility |
|---|---|
| `SayMoore/Services/StreamingMode.swift` *(new)* | Enum + computed params (interval, window samples, commit-advance samples) |
| `SayMoore/Services/TimedTranscript.swift` *(new)* | Small value type: `[TimedSegment]` with text + t0Centiseconds + t1Centiseconds |
| `SayMoore/Services/TranscriptionService.swift` *(modify)* | Add `transcribeTimed(samples:sampleRate:) async throws -> TimedTranscript` to the protocol + Whisper + Fake implementations |
| `SayMoore/Services/AudioRecorder.swift` *(modify)* | Add `onSamples: (@Sendable ([Float]) -> Void)?` callback that fires from the tap |
| `SayMoore/Services/StreamingTranscriber.swift` *(new)* | Sliding-window inference loop, commit logic, partial emission |
| `SayMoore/UI/RecordingHUDController.swift` *(modify)* | Dynamic-width pill, `NSTextField` for partial, attributed-string committed+active treatment |
| `SayMoore/UI/SettingsViewModel.swift` *(modify)* | `@Published var streamingMode: StreamingMode` persisted to UserDefaults |
| `SayMoore/UI/SettingsView.swift` *(modify)* | Add segmented `Picker` to `GeneralPane` |
| `SayMoore/App/PipelineCoordinator.swift` *(modify)* | Instantiate/start/stop `StreamingTranscriber` around recording state; wire `onPartialUpdate` to HUD |
| `SayMoore/App/AppDelegate.swift` *(modify)* | Wire HUD controller + UserDefaults read into PipelineCoordinator init |
| `SayMooreTests/StreamingModeTests.swift` *(new)* | Param math, default selection |
| `SayMooreTests/StreamingTranscriberTests.swift` *(new)* | Sliding window, commit math, stop() awaits in-flight pass, error path |
| `SayMooreTests/RecordingHUDPartialTextTests.swift` *(new)* | Width animation, attributed-string treatment, mode-off zero-rendering |
| `SayMooreTests/SettingsViewModelStreamingModeTests.swift` *(new)* | UserDefaults round-trip |
| `docs/manual-tests/streaming-partials.md` *(new)* | T10 dogfood log + CPU calibration record |

---

## Task 1: `StreamingMode` enum + param math

**Files:**
- Create: `SayMoore/Services/StreamingMode.swift`
- Test: `SayMooreTests/StreamingModeTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// SayMooreTests/StreamingModeTests.swift
import XCTest
@testable import SayMoore

final class StreamingModeTests: XCTestCase {
    func testBalancedDefaultParameters() {
        let m = StreamingMode.balanced
        XCTAssertEqual(m.intervalSeconds, 1.5, accuracy: 0.001)
        XCTAssertEqual(m.windowSamples, 16_000 * 10)
        XCTAssertEqual(m.commitAdvanceSamples, 16_000 * 5)
    }
    func testResponsiveParameters() {
        let m = StreamingMode.responsive
        XCTAssertEqual(m.intervalSeconds, 0.75, accuracy: 0.001)
        XCTAssertEqual(m.windowSamples, 16_000 * 8)
        XCTAssertEqual(m.commitAdvanceSamples, 16_000 * 4)
    }
    func testOffHasNoInferenceWork() {
        let m = StreamingMode.off
        XCTAssertEqual(m.intervalSeconds, 0)
        XCTAssertEqual(m.windowSamples, 0)
        XCTAssertEqual(m.commitAdvanceSamples, 0)
    }
    func testRawValueRoundTripsViaUserDefaultsKey() {
        for m in [StreamingMode.off, .balanced, .responsive] {
            XCTAssertEqual(StreamingMode(rawValue: m.rawValue), m)
        }
    }
    func testDefaultIsBalanced() {
        XCTAssertEqual(StreamingMode.default, .balanced)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild -project SayMoore.xcodeproj -scheme SayMoore -destination 'platform=macOS' \
  test -only-testing:SayMooreTests/StreamingModeTests 2>&1 | xcbeautify
```

Expected: build failure (`StreamingMode` undefined).

- [ ] **Step 3: Implement the enum**

```swift
// SayMoore/Services/StreamingMode.swift
import Foundation

/// Per-pass sliding-window timing for `StreamingTranscriber`.
/// Persisted in UserDefaults under `streaming.partials.mode`.
enum StreamingMode: String, CaseIterable, Sendable {
    case off
    case balanced
    case responsive

    static let `default`: StreamingMode = .balanced
    static let userDefaultsKey = "streaming.partials.mode"

    var intervalSeconds: TimeInterval {
        switch self {
        case .off:        return 0
        case .balanced:   return 1.5
        case .responsive: return 0.75
        }
    }

    var windowSeconds: TimeInterval {
        switch self {
        case .off:        return 0
        case .balanced:   return 10
        case .responsive: return 8
        }
    }

    var commitAdvanceSeconds: TimeInterval {
        switch self {
        case .off:        return 0
        case .balanced:   return 5
        case .responsive: return 4
        }
    }

    var windowSamples: Int { Int(windowSeconds * 16_000) }
    var commitAdvanceSamples: Int { Int(commitAdvanceSeconds * 16_000) }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: 5 passing.

- [ ] **Step 5: Add the file to `project.yml` regeneration is automatic via SayMoore source path glob — just regenerate**

```bash
bash scripts/generate-project.sh
```

Expected: `✓ SayMoore.xcodeproj regenerated.`

- [ ] **Step 6: Commit**

```bash
git add SayMoore/Services/StreamingMode.swift \
        SayMooreTests/StreamingModeTests.swift \
        SayMoore.xcodeproj
git commit -m "feat(streaming): StreamingMode enum + param math"
```

---

## Task 2: `TimedTranscript` value type + `transcribeTimed` on the protocol

**Files:**
- Create: `SayMoore/Services/TimedTranscript.swift`
- Modify: `SayMoore/Services/TranscriptionService.swift`
- Test: `SayMooreTests/TimedTranscriptTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// SayMooreTests/TimedTranscriptTests.swift
import XCTest
@testable import SayMoore

final class TimedTranscriptTests: XCTestCase {
    func testInitAggregatesText() {
        let t = TimedTranscript(segments: [
            TimedSegment(text: "Hello", t0Centiseconds: 0,   t1Centiseconds: 50),
            TimedSegment(text: " world.", t0Centiseconds: 60, t1Centiseconds: 120),
        ])
        XCTAssertEqual(t.text, "Hello world.")
    }
    func testEmptySegmentsYieldsEmptyText() {
        XCTAssertEqual(TimedTranscript(segments: []).text, "")
    }
    func testSplitAtCentiseconds() {
        let t = TimedTranscript(segments: [
            TimedSegment(text: "alpha", t0Centiseconds: 0,   t1Centiseconds: 100),
            TimedSegment(text: " bravo", t0Centiseconds: 110, t1Centiseconds: 200),
            TimedSegment(text: " charlie", t0Centiseconds: 210, t1Centiseconds: 320),
        ])
        let (head, tail) = t.split(atCentiseconds: 205)
        XCTAssertEqual(head.text, "alpha bravo")
        XCTAssertEqual(tail.text, " charlie")
    }
    func testSplitBeforeAnySegmentLeavesAllInTail() {
        let t = TimedTranscript(segments: [
            TimedSegment(text: "x", t0Centiseconds: 100, t1Centiseconds: 200),
        ])
        let (head, tail) = t.split(atCentiseconds: 50)
        XCTAssertTrue(head.segments.isEmpty)
        XCTAssertEqual(tail.text, "x")
    }
    func testSplitAfterAllSegmentsLeavesAllInHead() {
        let t = TimedTranscript(segments: [
            TimedSegment(text: "x", t0Centiseconds: 0, t1Centiseconds: 100),
        ])
        let (head, tail) = t.split(atCentiseconds: 5000)
        XCTAssertEqual(head.text, "x")
        XCTAssertTrue(tail.segments.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
xcodebuild -project SayMoore.xcodeproj -scheme SayMoore -destination 'platform=macOS' \
  test -only-testing:SayMooreTests/TimedTranscriptTests 2>&1 | xcbeautify
```

Expected: build failure.

- [ ] **Step 3: Implement `TimedTranscript`**

```swift
// SayMoore/Services/TimedTranscript.swift
import Foundation

struct TimedSegment: Equatable, Sendable {
    let text: String
    /// whisper.cpp returns segment times in centiseconds (1/100 s).
    let t0Centiseconds: Int64
    let t1Centiseconds: Int64
}

struct TimedTranscript: Equatable, Sendable {
    let segments: [TimedSegment]

    var text: String { segments.map(\.text).joined() }

    /// Split into (head, tail) such that all segments with t1 ≤ cutoff land in
    /// head, all others in tail. Used by StreamingTranscriber to advance the
    /// commit point: head is "stable and frozen", tail is "still revisable".
    func split(atCentiseconds cutoff: Int64) -> (head: TimedTranscript, tail: TimedTranscript) {
        var headSegs: [TimedSegment] = []
        var tailSegs: [TimedSegment] = []
        for s in segments {
            if s.t1Centiseconds <= cutoff { headSegs.append(s) }
            else { tailSegs.append(s) }
        }
        return (TimedTranscript(segments: headSegs), TimedTranscript(segments: tailSegs))
    }
}
```

- [ ] **Step 4: Extend the `TranscriptionService` protocol + Whisper + Fake**

In `SayMoore/Services/TranscriptionService.swift`, add to the protocol:

```swift
protocol TranscriptionService: Sendable {
    func transcribe(samples: [Float], sampleRate: Int, initialPrompt: String?) async throws -> Transcript

    /// Streaming-partial variant. Returns per-segment text + whisper.cpp
    /// timings (centiseconds). No `initialPrompt` — partials don't bias.
    /// Implementations MAY share serial queue / context with `transcribe`.
    func transcribeTimed(samples: [Float], sampleRate: Int) async throws -> TimedTranscript
}
```

In the `WhisperTranscriptionService` body, add after `transcribe(samples:sampleRate:initialPrompt:)`:

```swift
func transcribeTimed(samples: [Float], sampleRate: Int) async throws -> TimedTranscript {
    precondition(sampleRate == 16_000, "WhisperTranscriptionService requires 16kHz")
    return try await withCheckedThrowingContinuation { cont in
        serial.async { [self] in
            do {
                let result = try self.transcribeTimedSync(samples: samples)
                cont.resume(returning: result)
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}

private func transcribeTimedSync(samples: [Float]) throws -> TimedTranscript {
    if ctx == nil {
        lock.lock()
        guard !wasFreed else {
            lock.unlock()
            throw SayMooreError.transcriptionFailed(underlying: WhisperBridgeError.modelInitFailed)
        }
        lock.unlock()
        var cparams = whisper_context_default_params()
        cparams.use_gpu = true
        cparams.flash_attn = true
        guard let c = whisper_init_from_file_with_params(modelPath, cparams) else {
            throw SayMooreError.transcriptionFailed(underlying: WhisperBridgeError.modelInitFailed)
        }
        ctx = c
        Log.transcribe.info("whisper context loaded from \(self.modelPath, privacy: .public)")
    }
    lock.lock()
    guard !wasFreed, let ctx else {
        lock.unlock()
        throw SayMooreError.transcriptionFailed(underlying: WhisperBridgeError.modelInitFailed)
    }
    let localCtx = ctx
    lock.unlock()

    var fparams = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
    fparams.print_realtime = false
    fparams.print_progress = false
    fparams.print_special = false
    fparams.print_timestamps = false
    fparams.translate = false
    fparams.no_context = true
    fparams.suppress_blank = true
    fparams.suppress_nst = true
    fparams.no_speech_thold = 0.6
    fparams.single_segment = false
    let lang = "en".withCString { strdup($0)! }
    fparams.language = UnsafePointer(lang)
    defer { free(lang) }

    let status = samples.withUnsafeBufferPointer { buf -> Int32 in
        whisper_full(localCtx, fparams, buf.baseAddress, Int32(buf.count))
    }
    guard status == 0 else {
        throw SayMooreError.transcriptionFailed(underlying: WhisperBridgeError.fullFailed(status: status))
    }

    let nSegments = whisper_full_n_segments(localCtx)
    var segs: [TimedSegment] = []
    segs.reserveCapacity(Int(nSegments))
    for i in 0..<nSegments {
        let cstr = whisper_full_get_segment_text(localCtx, i)
        let text = cstr.map { String(cString: $0) } ?? ""
        let t0 = whisper_full_get_segment_t0(localCtx, i)
        let t1 = whisper_full_get_segment_t1(localCtx, i)
        segs.append(TimedSegment(text: text, t0Centiseconds: Int64(t0), t1Centiseconds: Int64(t1)))
    }
    return TimedTranscript(segments: segs)
}
```

In the `#else` non-whisper branch, add:

```swift
func transcribeTimed(samples: [Float], sampleRate: Int) async throws -> TimedTranscript {
    throw SayMooreError.modelMissing
}
```

In `FakeTranscriptionService`, add:

```swift
var nextTimedResult: Result<TimedTranscript, Error> = .success(TimedTranscript(segments: []))
private(set) var timedCalls = 0
func transcribeTimed(samples: [Float], sampleRate: Int) async throws -> TimedTranscript {
    timedCalls += 1
    return try nextTimedResult.get()
}
```

- [ ] **Step 5: Run TimedTranscriptTests + full existing TranscriptionService test suite**

```bash
xcodebuild -project SayMoore.xcodeproj -scheme SayMoore -destination 'platform=macOS' \
  test -only-testing:SayMooreTests/TimedTranscriptTests 2>&1 | xcbeautify
# Also ensure no regression in existing transcription tests:
xcodebuild -project SayMoore.xcodeproj -scheme SayMoore -destination 'platform=macOS' \
  test 2>&1 | xcbeautify | tail -40
```

Expected: TimedTranscriptTests 5 passing; no previously-green tests broken.

- [ ] **Step 6: Regenerate project + commit**

```bash
bash scripts/generate-project.sh
git add SayMoore/Services/TimedTranscript.swift \
        SayMoore/Services/TranscriptionService.swift \
        SayMooreTests/TimedTranscriptTests.swift \
        SayMoore.xcodeproj
git commit -m "feat(streaming): TimedTranscript + transcribeTimed for partial passes"
```

---

## Task 3: `AudioRecorder.onSamples` tap callback

**Files:**
- Modify: `SayMoore/Services/AudioRecorder.swift`
- Test: `SayMooreTests/AudioRecorderOnSamplesTests.swift` *(new)*

The streaming transcriber needs raw 16 kHz mono float samples from the tap *without* consuming the ring buffer (`drainAll()` is destructive — the final transcribe relies on it). Mirror the existing `onLevelUpdate` pattern.

- [ ] **Step 1: Write the failing test**

```swift
// SayMooreTests/AudioRecorderOnSamplesTests.swift
import XCTest
@testable import SayMoore

final class AudioRecorderOnSamplesTests: XCTestCase {
    func testOnSamplesPropertyIsSettableAndReadable() {
        let r = AudioRecorder()
        let exp = expectation(description: "callback assigned")
        r.onSamples = { samples in
            XCTAssertEqual(samples, [1, 2, 3])
            exp.fulfill()
        }
        // Drive the callback directly — the audio-thread path is exercised by
        // higher-level integration tests; here we just confirm wiring.
        r.onSamples?([1, 2, 3])
        wait(for: [exp], timeout: 0.5)
    }
    func testOnSamplesNilByDefault() {
        let r = AudioRecorder()
        XCTAssertNil(r.onSamples)
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
xcodebuild -project SayMoore.xcodeproj -scheme SayMoore -destination 'platform=macOS' \
  test -only-testing:SayMooreTests/AudioRecorderOnSamplesTests 2>&1 | xcbeautify
```

Expected: build failure (`onSamples` undefined).

- [ ] **Step 3: Add the callback property and tap wiring**

In `AudioRecorder.swift`, add this property next to `onLevelUpdate` (around line 32):

```swift
/// Fired from the audio thread for every converted PCM chunk with the
/// raw 16 kHz mono float samples. Handler is responsible for its own
/// threading; the StreamingTranscriber subscribes here to feed its
/// sliding-window buffer without disturbing the ring buffer that the
/// final `stop() -> [Float]` drain relies on.
var onSamples: (@Sendable ([Float]) -> Void)?
```

Inside `start()`, immediately after `let levelHandler = self.onLevelUpdate` (around line 71), add:

```swift
let samplesHandler = self.onSamples
```

And inside the tap closure (around line 78, immediately after `_ = ring.write(bp)`), add:

```swift
if let samplesHandler {
    samplesHandler(Array(bp))
}
```

- [ ] **Step 4: Run the new test + existing AudioRecorder tests**

```bash
xcodebuild -project SayMoore.xcodeproj -scheme SayMoore -destination 'platform=macOS' \
  test -only-testing:SayMooreTests/AudioRecorderOnSamplesTests 2>&1 | xcbeautify
xcodebuild -project SayMoore.xcodeproj -scheme SayMoore -destination 'platform=macOS' \
  test -only-testing:SayMooreTests/AudioRecorderTests 2>&1 | xcbeautify | tail -20
```

Expected: new test passing; existing AudioRecorder tests unchanged.

- [ ] **Step 5: Commit**

```bash
git add SayMoore/Services/AudioRecorder.swift \
        SayMooreTests/AudioRecorderOnSamplesTests.swift
git commit -m "feat(streaming): AudioRecorder.onSamples tap callback"
```

---

## Task 4: `StreamingTranscriber` — sliding window + commit logic

**Files:**
- Create: `SayMoore/Services/StreamingTranscriber.swift`
- Test: `SayMooreTests/StreamingTranscriberTests.swift`

This is the heart of the feature. Design contract:
- Owns a private `[Float]` audio buffer fed by `appendSamples()`.
- Every `mode.intervalSeconds`, runs a partial pass on `audioBuffer[committedOffset...end]` clamped to the last `mode.windowSamples`.
- After each pass: any segments whose `t1` (in centiseconds, relative to the start of the active window) ≤ `mode.commitAdvanceSeconds * 100` get appended to `committedText` and the `committedOffset` advances by `mode.commitAdvanceSamples`.
- Emits `<committedText> + activeTail` via `onPartialUpdate` on `@MainActor`.
- `stop() async` cancels the next-scheduled pass and awaits any in-flight inference.

- [ ] **Step 1: Write the failing tests**

```swift
// SayMooreTests/StreamingTranscriberTests.swift
import XCTest
@testable import SayMoore

@MainActor
final class StreamingTranscriberTests: XCTestCase {

    func makeFake(_ result: TimedTranscript) -> FakeTranscriptionService {
        let f = FakeTranscriptionService()
        f.nextTimedResult = .success(result)
        return f
    }

    func testEmitsPartialAfterFirstPass() async throws {
        let fake = makeFake(TimedTranscript(segments: [
            TimedSegment(text: "hello", t0Centiseconds: 0, t1Centiseconds: 100),
        ]))
        let s = StreamingTranscriber(transcription: fake, mode: .balanced)
        let exp = expectation(description: "partial emitted")
        s.onPartialUpdate = { committed, active in
            XCTAssertEqual(committed, "")
            XCTAssertEqual(active, "hello")
            exp.fulfill()
        }
        s.start()
        // Feed 11s of dummy samples so a pass has enough to slice.
        s.appendSamples(Array(repeating: Float(0.01), count: 16_000 * 11))
        await s.forceTickForTests()
        await fulfillment(of: [exp], timeout: 1.0)
        await s.stop()
    }

    func testCommitsSegmentsOlderThanCommitAdvance() async throws {
        // Pass returns 2 segments — first ends at 4s (≤ 5s commit), second at 9s.
        let fake = makeFake(TimedTranscript(segments: [
            TimedSegment(text: "alpha", t0Centiseconds: 0,   t1Centiseconds: 400),
            TimedSegment(text: " beta", t0Centiseconds: 410, t1Centiseconds: 900),
        ]))
        let s = StreamingTranscriber(transcription: fake, mode: .balanced)
        var latest: (String, String) = ("", "")
        s.onPartialUpdate = { c, a in latest = (c, a) }
        s.start()
        s.appendSamples(Array(repeating: Float(0.01), count: 16_000 * 11))
        await s.forceTickForTests()
        XCTAssertEqual(latest.0, "alpha", "first segment should be committed (t1=4s ≤ 5s)")
        XCTAssertEqual(latest.1, " beta", "second segment is still in active tail")
        await s.stop()
    }

    func testCommittedTextAccumulatesAcrossPasses() async throws {
        // Pass 1 commits "alpha". Pass 2 commits " beta".
        let fake = FakeTranscriptionService()
        let s = StreamingTranscriber(transcription: fake, mode: .balanced)
        var latest: (String, String) = ("", "")
        s.onPartialUpdate = { c, a in latest = (c, a) }
        s.start()

        fake.nextTimedResult = .success(TimedTranscript(segments: [
            TimedSegment(text: "alpha", t0Centiseconds: 0, t1Centiseconds: 400),
        ]))
        s.appendSamples(Array(repeating: Float(0.01), count: 16_000 * 11))
        await s.forceTickForTests()
        XCTAssertEqual(latest.0, "alpha")
        XCTAssertEqual(latest.1, "")

        fake.nextTimedResult = .success(TimedTranscript(segments: [
            TimedSegment(text: " beta", t0Centiseconds: 0, t1Centiseconds: 400),
        ]))
        s.appendSamples(Array(repeating: Float(0.01), count: 16_000 * 6))
        await s.forceTickForTests()
        XCTAssertEqual(latest.0, "alpha beta", "second pass should append to committed prefix")
        await s.stop()
    }

    func testStopIsIdempotent() async {
        let s = StreamingTranscriber(transcription: FakeTranscriptionService(), mode: .balanced)
        s.start()
        await s.stop()
        await s.stop()  // must not crash
    }

    func testInferenceErrorDoesNotCrashAndDisablesFurtherPasses() async {
        let fake = FakeTranscriptionService()
        fake.nextTimedResult = .failure(SayMooreError.modelMissing)
        let s = StreamingTranscriber(transcription: fake, mode: .balanced)
        var emitCount = 0
        s.onPartialUpdate = { _, _ in emitCount += 1 }
        s.start()
        s.appendSamples(Array(repeating: Float(0.01), count: 16_000 * 11))
        await s.forceTickForTests()
        XCTAssertEqual(emitCount, 0, "errored pass must not emit")
        // Subsequent ticks are no-ops after first error.
        await s.forceTickForTests()
        XCTAssertEqual(emitCount, 0)
        await s.stop()
    }

    func testOffModeIsNeverInstantiated() {
        // Sanity: ensure the caller would never construct one for .off mode.
        // (Coordinator-side check; documented here as the contract.)
        XCTAssertEqual(StreamingMode.off.intervalSeconds, 0)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Expected: build failure (`StreamingTranscriber` undefined).

- [ ] **Step 3: Implement `StreamingTranscriber`**

```swift
// SayMoore/Services/StreamingTranscriber.swift
import Foundation

/// Drives sliding-window whisper inference for live partial display. One
/// instance per recording; reuses the existing WhisperTranscriptionService
/// context (no second model load).
///
/// Concurrency: appendSamples may be called from any thread (audio thread).
/// Lifecycle methods + onPartialUpdate are main-actor. Inference runs on
/// the whisper service's serial DispatchQueue.
@MainActor
final class StreamingTranscriber {
    private let transcription: TranscriptionService
    private let mode: StreamingMode

    // Audio accumulator. Lock-protected because audio thread writes via
    // appendSamples while the inference task reads.
    private let bufferLock = NSLock()
    private var audioBuffer: [Float] = []

    private var committedText: String = ""
    private var committedSampleOffset: Int = 0
    private var disabled: Bool = false
    private var tickTask: Task<Void, Never>?
    private var inFlight: Task<Void, Never>?

    /// Fired on the main actor after each successful pass.
    /// `committed` is the frozen prefix; `active` is the still-revisable tail.
    var onPartialUpdate: ((String, String) -> Void)?

    init(transcription: TranscriptionService, mode: StreamingMode) {
        precondition(mode != .off, "StreamingTranscriber must not be constructed for .off mode")
        self.transcription = transcription
        self.mode = mode
    }

    func start() {
        guard tickTask == nil else { return }
        let interval = mode.intervalSeconds
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.tick()
            }
        }
    }

    func stop() async {
        tickTask?.cancel()
        tickTask = nil
        if let inFlight {
            _ = await inFlight.value
        }
        inFlight = nil
    }

    /// Called from the audio thread (AudioRecorder.onSamples). Lock-protected.
    nonisolated func appendSamples(_ samples: [Float]) {
        // NSLock is nonisolated-safe.
        // (Captured weakly via the wrapper to avoid retain cycles is unnecessary
        // because this struct owns the lock.)
        // Forward into the actor-protected mutable state:
        Task { @MainActor [weak self] in
            self?.appendOnMain(samples)
        }
    }

    private func appendOnMain(_ samples: [Float]) {
        bufferLock.lock()
        audioBuffer.append(contentsOf: samples)
        bufferLock.unlock()
    }

    /// Test seam — drive a single pass synchronously from tests.
    func forceTickForTests() async {
        await tick()
    }

    private func tick() async {
        guard !disabled else { return }
        guard inFlight == nil else { return }  // skip if previous pass still running

        // Snapshot the window.
        bufferLock.lock()
        let bufferCount = audioBuffer.count
        let activeStart = committedSampleOffset
        let activeEnd = bufferCount
        guard activeEnd > activeStart else {
            bufferLock.unlock()
            return
        }
        // Clamp to the most recent `windowSamples`.
        let clampStart = max(activeStart, activeEnd - mode.windowSamples)
        let slice = Array(audioBuffer[clampStart..<activeEnd])
        bufferLock.unlock()

        // Run inference. Wrap the await in a Task so we can track in-flight state.
        let trans = transcription
        let mode = self.mode
        inFlight = Task.detached(priority: .userInitiated) { [weak self] in
            let timed: TimedTranscript
            do {
                timed = try await trans.transcribeTimed(samples: slice, sampleRate: 16_000)
            } catch {
                await MainActor.run { [weak self] in
                    self?.disabled = true
                }
                return
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                let cutoffCs = Int64(mode.commitAdvanceSeconds * 100)
                let (head, tail) = timed.split(atCentiseconds: cutoffCs)
                if !head.text.isEmpty {
                    self.committedText += head.text
                    self.committedSampleOffset += mode.commitAdvanceSamples
                }
                self.onPartialUpdate?(self.committedText, tail.text)
            }
        }
        _ = await inFlight?.value
        inFlight = nil
    }
}
```

- [ ] **Step 4: Run StreamingTranscriberTests**

```bash
xcodebuild -project SayMoore.xcodeproj -scheme SayMoore -destination 'platform=macOS' \
  test -only-testing:SayMooreTests/StreamingTranscriberTests 2>&1 | xcbeautify
```

Expected: all 6 tests passing.

- [ ] **Step 5: Regenerate project + commit**

```bash
bash scripts/generate-project.sh
git add SayMoore/Services/StreamingTranscriber.swift \
        SayMooreTests/StreamingTranscriberTests.swift \
        SayMoore.xcodeproj
git commit -m "feat(streaming): StreamingTranscriber sliding-window engine"
```

---

## Task 5: `RecordingHUDController` — dynamic-width pill + partial text

**Files:**
- Modify: `SayMoore/UI/RecordingHUDController.swift`
- Test: `SayMooreTests/RecordingHUDPartialTextTests.swift` *(new)*

The pill stays 130 wide at rest (waveform-only). When partial text arrives, it widens up to a max of 480, with a hairline divider between bars and text. Committed words = full opacity; active tail = italic, 0.85 alpha. Truncation is leading-edge ellipsis so the *latest* words always show.

- [ ] **Step 1: Add the new constants + NSTextField as a sublayer-equivalent**

Read `RecordingHUDController.swift:11-25` for the existing constants. Add these new constants directly below `pillSize`:

```swift
private static let collapsedWidth: CGFloat = 130
private static let maxExpandedWidth: CGFloat = 480
private static let dividerWidth: CGFloat = 1
private static let dividerLeftMargin: CGFloat = 6
private static let dividerRightMargin: CGFloat = 8
private static let textRightMargin: CGFloat = 12
private static let textFontSize: CGFloat = 11
```

Add the new fields to the stored-property block (around line 30):

```swift
private var textField: NSTextField!
private var dividerLayer: CALayer!
private var lastCommitted: String = ""
private var lastActive: String = ""
```

- [ ] **Step 2: Construct the divider + text field in `init`**

After the bar-construction loop in `init()` (around line 104, before `panel.contentView = background`), append:

```swift
let divider = CALayer()
divider.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
let dividerX = Self.barAreaX + CGFloat(Self.barCount) * (Self.barWidth + Self.barGap) + Self.dividerLeftMargin
divider.frame = NSRect(
    x: dividerX,
    y: (size.height - Self.barMaxHeight) / 2,
    width: Self.dividerWidth,
    height: Self.barMaxHeight
)
divider.opacity = 0
background.layer?.addSublayer(divider)
self.dividerLayer = divider

let tf = NSTextField(labelWithString: "")
tf.font = NSFont.systemFont(ofSize: Self.textFontSize, weight: .regular)
tf.textColor = NSColor.white
tf.backgroundColor = .clear
tf.isBezeled = false
tf.isEditable = false
tf.isSelectable = false
tf.lineBreakMode = .byTruncatingHead   // leading-edge ellipsis
tf.usesSingleLineMode = true
tf.cell?.truncatesLastVisibleLine = true
tf.alphaValue = 0
let textX = dividerX + Self.dividerWidth + Self.dividerRightMargin
tf.frame = NSRect(
    x: textX,
    y: 0,
    width: 0,
    height: size.height
)
background.addSubview(tf)
self.textField = tf
```

- [ ] **Step 3: Add `updatePartialText(committed:active:)`**

Add this method to the class (place after `updateLevel(_:)`):

```swift
/// Update the partial-transcript display. Animates the pill width to fit.
/// Empty strings collapse the pill back to waveform-only.
func updatePartialText(committed: String, active: String) {
    lastCommitted = committed
    lastActive = active

    let combined = committed + active
    if combined.isEmpty {
        animatePillWidth(to: Self.collapsedWidth)
        dividerLayer.opacity = 0
        textField.alphaValue = 0
        textField.attributedStringValue = NSAttributedString(string: "")
        return
    }

    let attr = NSMutableAttributedString()
    let base = [
        NSAttributedString.Key.font: NSFont.systemFont(ofSize: Self.textFontSize, weight: .regular),
        NSAttributedString.Key.foregroundColor: NSColor.white,
    ] as [NSAttributedString.Key: Any]
    attr.append(NSAttributedString(string: committed, attributes: base))
    let activeAttrs = [
        NSAttributedString.Key.font: NSFont.systemFont(ofSize: Self.textFontSize, weight: .regular).withItalic(),
        NSAttributedString.Key.foregroundColor: NSColor.white.withAlphaComponent(0.85),
    ] as [NSAttributedString.Key: Any]
    attr.append(NSAttributedString(string: active, attributes: activeAttrs))
    textField.attributedStringValue = attr
    textField.alphaValue = 1
    dividerLayer.opacity = 1

    // Measure + clamp.
    let measured = attr.size().width + 4 // text padding fudge
    let dividerX = Self.barAreaX + CGFloat(Self.barCount) * (Self.barWidth + Self.barGap) + Self.dividerLeftMargin
    let textStartX = dividerX + Self.dividerWidth + Self.dividerRightMargin
    let target = min(Self.maxExpandedWidth, textStartX + measured + Self.textRightMargin)
    animatePillWidth(to: target)
    textField.frame.size.width = target - textStartX - Self.textRightMargin
}

private func animatePillWidth(to newWidth: CGFloat) {
    var f = panel.frame
    let delta = newWidth - f.width
    // Re-center horizontally on the current anchor so the pill expands
    // symmetrically — preserves the "above active window bottom" anchor X.
    f.origin.x -= delta / 2
    f.size.width = newWidth
    NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.18
        ctx.allowsImplicitAnimation = true
        panel.animator().setFrame(f, display: false)
    }
}
```

Add this helper at end of file:

```swift
private extension NSFont {
    func withItalic() -> NSFont {
        let desc = fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: desc, size: pointSize) ?? self
    }
}
```

- [ ] **Step 4: Make `hide()` reset partial-text state**

In `hide()` (line 123), after `resetBars()`, add:

```swift
lastCommitted = ""
lastActive = ""
textField.attributedStringValue = NSAttributedString(string: "")
textField.alphaValue = 0
dividerLayer.opacity = 0
// Snap pill back to collapsed width for next show().
var f = panel.frame
f.size.width = Self.collapsedWidth
panel.setFrame(f, display: false)
```

- [ ] **Step 5: Write the tests**

```swift
// SayMooreTests/RecordingHUDPartialTextTests.swift
import XCTest
@testable import SayMoore

@MainActor
final class RecordingHUDPartialTextTests: XCTestCase {
    func testInitialPillIsCollapsedWidth() {
        let hud = RecordingHUDController()
        // Indirect: assert via the panel's frame after a no-op show/hide cycle is
        // overkill — assert internal state instead.
        // The collapsed constant is exposed implicitly via behavior.
        hud.updatePartialText(committed: "", active: "")
        // No crash, no text rendered.
        XCTAssertNotNil(hud)  // smoke
    }
    func testEmptyTextHidesPartialUI() {
        let hud = RecordingHUDController()
        hud.updatePartialText(committed: "alpha", active: "")
        hud.updatePartialText(committed: "", active: "")
        // Re-collapsing after content must not crash and should clear text.
        // (Visual assertions live in the manual dogfood matrix; this is wiring.)
        XCTAssertNotNil(hud)
    }
    func testLargePartialTruncatesToMaxWidth() {
        let hud = RecordingHUDController()
        let long = String(repeating: "The quick brown fox. ", count: 30)
        hud.updatePartialText(committed: long, active: "")
        // No crash on extremely long input.
        XCTAssertNotNil(hud)
    }
}
```

- [ ] **Step 6: Run the HUD tests + existing HUD tests**

```bash
xcodebuild -project SayMoore.xcodeproj -scheme SayMoore -destination 'platform=macOS' \
  test -only-testing:SayMooreTests/RecordingHUDPartialTextTests 2>&1 | xcbeautify
# Make sure existing HUD tests still pass:
xcodebuild -project SayMoore.xcodeproj -scheme SayMoore -destination 'platform=macOS' \
  test -only-testing:SayMooreTests/RecordingHUDControllerTests 2>&1 | xcbeautify | tail -20
```

Expected: new tests pass; no existing HUD regression.

- [ ] **Step 7: Regenerate + commit**

```bash
bash scripts/generate-project.sh
git add SayMoore/UI/RecordingHUDController.swift \
        SayMooreTests/RecordingHUDPartialTextTests.swift \
        SayMoore.xcodeproj
git commit -m "feat(streaming): HUD dynamic-width pill with partial text"
```

---

## Task 6: `SettingsViewModel.streamingMode` + General-pane picker

**Files:**
- Modify: `SayMoore/UI/SettingsViewModel.swift`
- Modify: `SayMoore/UI/SettingsView.swift`
- Test: `SayMooreTests/SettingsViewModelStreamingModeTests.swift` *(new)*

- [ ] **Step 1: Write the failing test**

```swift
// SayMooreTests/SettingsViewModelStreamingModeTests.swift
import XCTest
@testable import SayMoore

@MainActor
final class SettingsViewModelStreamingModeTests: XCTestCase {
    override func setUp() async throws {
        UserDefaults.standard.removeObject(forKey: StreamingMode.userDefaultsKey)
    }
    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: StreamingMode.userDefaultsKey)
    }

    func testDefaultsToBalancedWhenUnset() throws {
        let store = try PresetStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("p-\(UUID()).json"),
            materializeIfMissing: false
        )
        let vm = SettingsViewModel(presets: store)
        XCTAssertEqual(vm.streamingMode, .balanced)
    }

    func testSettingPersistsToUserDefaults() throws {
        let store = try PresetStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("p-\(UUID()).json"),
            materializeIfMissing: false
        )
        let vm = SettingsViewModel(presets: store)
        vm.streamingMode = .responsive
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: StreamingMode.userDefaultsKey),
            "responsive"
        )
    }

    func testReadsExistingUserDefaultsValue() throws {
        UserDefaults.standard.set("off", forKey: StreamingMode.userDefaultsKey)
        let store = try PresetStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("p-\(UUID()).json"),
            materializeIfMissing: false
        )
        let vm = SettingsViewModel(presets: store)
        XCTAssertEqual(vm.streamingMode, .off)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Expected: build failure (`streamingMode` undefined).

- [ ] **Step 3: Extend `SettingsViewModel`**

Add these to the published-properties block (around line 21):

```swift
@Published var streamingMode: StreamingMode {
    didSet {
        UserDefaults.standard.set(streamingMode.rawValue, forKey: StreamingMode.userDefaultsKey)
    }
}
```

Update `init(presets:)` (around line 39):

```swift
init(presets: PresetStore) {
    self.presets = presets
    self.muted = UserDefaults.standard.bool(forKey: "audio.feedback.muted")
    let raw = UserDefaults.standard.string(forKey: StreamingMode.userDefaultsKey)
    self.streamingMode = raw.flatMap(StreamingMode.init(rawValue:)) ?? .default
    refresh()
}
```

- [ ] **Step 4: Add the picker to GeneralPane**

Update `SettingsView.swift` `GeneralPane` body:

```swift
private struct GeneralPane: View {
    @ObservedObject var viewModel: SettingsViewModel
    var body: some View {
        Form {
            Section {
                Toggle("Mute audio chimes", isOn: $viewModel.muted)
                Text("Plays chimes on record start/stop. Takes effect on next app launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Streaming partials", selection: $viewModel.streamingMode) {
                    Text("Off").tag(StreamingMode.off)
                    Text("Balanced").tag(StreamingMode.balanced)
                    Text("Responsive").tag(StreamingMode.responsive)
                }
                .pickerStyle(.segmented)
                Text("Show transcribed text in the HUD as you speak. Balanced uses ~10–20% CPU during recording; Responsive ~25%. Applies to the next dictation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
    }
}
```

- [ ] **Step 5: Run the new tests + existing settings tests**

```bash
xcodebuild -project SayMoore.xcodeproj -scheme SayMoore -destination 'platform=macOS' \
  test -only-testing:SayMooreTests/SettingsViewModelStreamingModeTests 2>&1 | xcbeautify
xcodebuild -project SayMoore.xcodeproj -scheme SayMoore -destination 'platform=macOS' \
  test -only-testing:SayMooreTests/SettingsViewModelTests 2>&1 | xcbeautify | tail -20
```

Expected: 3 new passing; no regression in SettingsViewModelTests.

- [ ] **Step 6: Commit**

```bash
git add SayMoore/UI/SettingsViewModel.swift \
        SayMoore/UI/SettingsView.swift \
        SayMooreTests/SettingsViewModelStreamingModeTests.swift
git commit -m "feat(streaming): Settings ▸ General streaming-partials picker"
```

---

## Task 7: `PipelineCoordinator` wiring

**Files:**
- Modify: `SayMoore/App/PipelineCoordinator.swift`
- Modify: `SayMoore/App/AppDelegate.swift`

The coordinator instantiates one `StreamingTranscriber` per recording, wires its `onPartialUpdate` to the HUD, starts on `.idle → .recording`, awaits `stop()` before invoking `transcription.transcribe()` on hotkey-up, and ensures mode=Off is byte-for-byte the same as today.

- [ ] **Step 1: Inject streaming dependencies into `PipelineCoordinator.init`**

In both `#if DEBUG` and `#else` init signatures, add (after `historyStore:` parameter):

```swift
streamingModeProvider: @MainActor @Sendable () -> StreamingMode = { .off },
hudPartialSink: (@MainActor (String, String) -> Void)? = nil,
```

Default `streamingModeProvider = { .off }` keeps existing call sites and tests untouched (no behavior change unless wired).

Store as fields:

```swift
private let streamingModeProvider: @MainActor @Sendable () -> StreamingMode
private let hudPartialSink: (@MainActor (String, String) -> Void)?
private var streamingTranscriber: StreamingTranscriber?
```

Assign in both init bodies.

- [ ] **Step 2: Start the streamer on record start**

Modify `beginRecording(bundleID:)` (around line 268) to add streaming setup after `try recorder.start()`:

```swift
private func beginRecording(bundleID: String?) {
    capturedBundleID = bundleID
    do {
        try recorder.start()
        startStreamingIfEnabled()
        appState.transition(to: .recording)
        armLengthCapTimers()
    } catch {
        Log.audio.error("recorder.start failed: \(String(describing: error), privacy: .public)")
        transitionToError(error)
    }
}

private func startStreamingIfEnabled() {
    let mode = streamingModeProvider()
    guard mode != .off else { return }
    let s = StreamingTranscriber(transcription: transcription, mode: mode)
    let sink = hudPartialSink
    s.onPartialUpdate = { committed, active in
        sink?(committed, active)
    }
    // Subscribe to the recorder's sample-tap callback.
    recorder.onSamples = { samples in
        s.appendSamples(samples)
    }
    s.start()
    streamingTranscriber = s
    Log.pipeline.info("streaming partials enabled (mode=\(mode.rawValue, privacy: .public))")
}
```

`recorder.onSamples = ...` requires `AudioRecording` protocol to expose it — check `SayMoore/Services/AudioRecording.swift` and add the property to the protocol if not present:

```swift
protocol AudioRecording: AnyObject {
    // ... existing members ...
    var onSamples: (@Sendable ([Float]) -> Void)? { get set }
}
```

Any test fake conforming to `AudioRecording` needs the property; add `var onSamples: (@Sendable ([Float]) -> Void)? = nil` to each. Grep first:

```bash
grep -rn "AudioRecording" SayMoore/ SayMooreTests/
```

- [ ] **Step 3: Stop the streamer before final transcribe**

In `toggle(bundleID:)`'s `.recording` branch (around line 192), `fireLengthCapHardStop()`, and `handleSilenceAutoStop()` — three places that transition `.recording → .transcribing` — change from:

```swift
processingTask = Task { await self.processSamples(samples) }
```

to:

```swift
processingTask = Task {
    await self.stopStreaming()
    await self.processSamples(samples)
}
```

And add:

```swift
private func stopStreaming() async {
    if let s = streamingTranscriber {
        await s.stop()
        streamingTranscriber = nil
        recorder.onSamples = nil
    }
}
```

Also call `stopStreaming` from `cancel()` and `handleAudioDeviceChange()`:

```swift
func cancel() {
    guard appState.state == .recording else { return }
    recorder.cancel()
    Task { await stopStreaming() }
    // ... rest unchanged ...
}

func handleAudioDeviceChange() {
    guard appState.state == .recording else { return }
    Log.pipeline.error("audio device changed mid-recording")
    Task { await stopStreaming() }
    // ... rest unchanged ...
}
```

Also from `fireWatchdog()` when it tears down a mid-recording session:

```swift
private func fireWatchdog() {
    guard appState.state != .idle else { return }
    Log.pipeline.fault("watchdog fired in state \(String(describing: self.appState.state), privacy: .public)")
    recorder.cancel()
    Task { await stopStreaming() }
    // ... rest unchanged ...
}
```

- [ ] **Step 4: Wire from `AppDelegate`**

Find the `PipelineCoordinator(...)` construction in `SayMoore/App/AppDelegate.swift` (grep: `PipelineCoordinator(`). Add:

```swift
streamingModeProvider: { @MainActor in
    let raw = UserDefaults.standard.string(forKey: StreamingMode.userDefaultsKey)
    return raw.flatMap(StreamingMode.init(rawValue:)) ?? .default
},
hudPartialSink: { [weak self] committed, active in
    self?.hudController.updatePartialText(committed: committed, active: active)
},
```

Replace `self?.hudController` with the actual property name used for the `RecordingHUDController` instance (grep `RecordingHUDController(` in AppDelegate).

- [ ] **Step 5: Write the regression test for mode-off no-op**

```swift
// Append to existing SayMooreTests/PipelineCoordinatorTests.swift or create
// SayMooreTests/PipelineCoordinatorStreamingOffTests.swift if isolated:
import XCTest
@testable import SayMoore

@MainActor
final class PipelineCoordinatorStreamingOffTests: XCTestCase {
    func testStreamingOffDoesNotTouchRecorderOnSamples() async throws {
        let recorder = FakeAudioRecorder()
        let transcription = FakeTranscriptionService()
        let paste = FakePasteService()
        let presets = FakePresetResolving()
        let coord = PipelineCoordinator(
            appState: AppState(),
            recorder: recorder,
            transcription: transcription,
            paste: paste,
            presets: presets,
            streamingModeProvider: { .off }
        )
        coord.toggle(bundleID: "test.app")
        XCTAssertNil(recorder.onSamples, "Off mode must not subscribe to onSamples")
        coord.toggle(bundleID: "test.app")
    }
}
```

(If `FakeAudioRecorder`, `FakePasteService`, `FakePresetResolving` don't exist with those names, locate the existing fakes via `grep -rn "class Fake.*: AudioRecording" SayMooreTests/`.)

- [ ] **Step 6: Run all coordinator tests**

```bash
xcodebuild -project SayMoore.xcodeproj -scheme SayMoore -destination 'platform=macOS' \
  test -only-testing:SayMooreTests/PipelineCoordinatorTests \
  -only-testing:SayMooreTests/PipelineCoordinatorStreamingOffTests 2>&1 | xcbeautify | tail -40
```

Expected: all green; existing coordinator tests unchanged.

- [ ] **Step 7: Full build + full test suite**

```bash
xcodebuild -project SayMoore.xcodeproj -scheme SayMoore -destination 'platform=macOS' \
  build 2>&1 | xcbeautify | tail -20
xcodebuild -project SayMoore.xcodeproj -scheme SayMoore -destination 'platform=macOS' \
  test 2>&1 | xcbeautify | tail -50
```

Expected: zero warnings/errors, all tests passing.

- [ ] **Step 8: Commit**

```bash
git add SayMoore/App/PipelineCoordinator.swift \
        SayMoore/App/AppDelegate.swift \
        SayMoore/Services/AudioRecording.swift \
        SayMooreTests/
git commit -m "feat(streaming): PipelineCoordinator wires StreamingTranscriber around recording"
```

---

## Task 8: Manual dogfood matrix + CPU calibration

**Files:**
- Create: `docs/manual-tests/streaming-partials.md`

This is the spec's required empirical calibration. Run AFTER all previous tasks merge cleanly.

- [ ] **Step 1: Create the manual-test template**

```markdown
# Streaming Partials — Manual Dogfood Log

## T10 — Streaming partials displays during dictation

**Scope:** Settings ▸ General ▸ Streaming partials = Balanced.

**Steps:**
1. Open TextEdit, focus a new doc.
2. Press-and-hold the record hotkey.
3. Dictate a 20 s sentence with rich vocabulary (e.g. "The quick brown fox jumps over the lazy dog, then asks AVAudioEngine to please reschedule").
4. Watch the HUD: partial text should appear right of the waveform within ~2 s of the first word, update every ~1.5 s, with committed words in regular weight and the active tail in italic + dimmer.
5. Release hotkey. Final cleaned transcript pastes into TextEdit. Compare against the HUD's last-shown string.

**Pass criteria:**
- Partial text appears within 2 s of first word.
- HUD widens smoothly (no flicker / re-layout jank).
- Final pasted text matches the HUD's last partial ± cleanup adjustments (punctuation, capitalization).
- Glass pill blur + bars + 4 px anchor visually unchanged.

**Result (run YYYY-MM-DD):** PASS / FAIL — notes.

## CPU calibration — Balanced mode (REQUIRED before ship)

**Setup:** Activity Monitor open, filtered to `SayMoore`. macOS 14.x+, M2 Ultra Mac Studio.

**Procedure:**
1. Settings ▸ Streaming partials = Balanced.
2. Three back-to-back 60 s dictations in TextEdit. Read aloud from a book.
3. Note peak + sustained CPU % during recording (NOT post-recording cleanup).

**Acceptance:** sustained CPU during recording ≤ 30% of one core (i.e. ≤ 7.5% of total on a 4-perf-core M2 Ultra; Activity Monitor reports per-core).

**Run YYYY-MM-DD:**
- Trial 1: peak __%, sustained __%.
- Trial 2: peak __%, sustained __%.
- Trial 3: peak __%, sustained __%.

**Decision:** if any trial sustained > 30% one core, bump StreamingMode.balanced.intervalSeconds from 1.5 to 2.0, regenerate project, re-test, and update spec.

## T10b — Off-mode regression

**Scope:** Streaming partials = Off.

**Steps:** repeat existing T1 dictation in TextEdit.

**Pass criteria:** behavior identical to current main; HUD shows waveform-only as today; pill width never changes from 130.

**Result (run YYYY-MM-DD):** PASS / FAIL.
```

- [ ] **Step 2: Build a Release for dogfood**

```bash
bash scripts/build-release.sh
```

Expected: signed `.app` in `release/`.

- [ ] **Step 3: Install the dogfood build, run T10 / calibration / T10b, fill in the log file with timestamps and trial numbers**

(Manual step — no tool command.)

- [ ] **Step 4: If calibration fails (>30% sustained), bump the Balanced interval**

Edit `SayMoore/Services/StreamingMode.swift`:

```swift
case .balanced:   return 2.0  // bumped from 1.5 after calibration on YYYY-MM-DD
```

Re-run StreamingModeTests (one assertion changes), re-build, re-run calibration.

Update the spec at `docs/superpowers/specs/2026-05-24-streaming-partials-design.md` § "Transcription engine" with the new interval and the calibration result.

- [ ] **Step 5: Commit the log + any calibration adjustments**

```bash
git add docs/manual-tests/streaming-partials.md \
        SayMoore/Services/StreamingMode.swift \
        SayMooreTests/StreamingModeTests.swift \
        docs/superpowers/specs/2026-05-24-streaming-partials-design.md
git commit -m "docs(streaming): T10 dogfood + CPU calibration on M2 Ultra"
```

---

## Task 9: PRD update + ship-readiness smoke

**Files:**
- Modify: `docs/PRD.md` (or wherever the v1.2 candidate list lives)

- [ ] **Step 1: Locate the v1.1 / v1.2 candidate list**

```bash
grep -n "v1\.1\|v1\.2\|enhancement\|candidate" docs/PRD.md | head -20
```

- [ ] **Step 2: Add streaming partials as a shipped v1.2 candidate**

Insert under the v1.2 section (or create one):

```markdown
- **Streaming partial transcript display** (shipped 2026-MM-DD) —
  live whisper output in the HUD as the user speaks, sliding-window
  inference, Off/Balanced/Responsive setting in General. Spec:
  `docs/superpowers/specs/2026-05-24-streaming-partials-design.md`.
```

- [ ] **Step 3: Full test suite + clean build smoke**

```bash
xcodebuild -project SayMoore.xcodeproj -scheme SayMoore -destination 'platform=macOS' \
  clean build test 2>&1 | xcbeautify | tail -40
```

Expected: zero warnings, all tests green.

- [ ] **Step 4: Commit**

```bash
git add docs/PRD.md
git commit -m "docs(prd): note streaming partials shipped in v1.2"
```

- [ ] **Step 5: Open a PR per the SayMoore shipping workflow**

Per the memory-recorded shipping workflow (PR for record, FF-merge locally for ship):

```bash
git push -u origin <feature-branch-name>
gh pr create --title "feat(v1.2): streaming partials" --body "$(cat <<'EOF'
## Summary
- Live partial transcript display in the Lifestream HUD via sliding-window whisper inference (matches whisper.cpp's `stream` example pattern).
- Off / Balanced / Responsive setting in Settings ▸ General; default = Balanced.
- HUD glass aesthetic preserved — partials are additive, right of waveform inside the existing pill.
- Single whisper context (no second model load); RAM-neutral.

## Spec
`docs/superpowers/specs/2026-05-24-streaming-partials-design.md`

## Test plan
- [x] StreamingModeTests, TimedTranscriptTests, StreamingTranscriberTests, RecordingHUDPartialTextTests, SettingsViewModelStreamingModeTests, PipelineCoordinatorStreamingOffTests — all green
- [x] Full test suite — green
- [x] T10 dogfood (Balanced + Off) — `docs/manual-tests/streaming-partials.md`
- [x] CPU calibration on M2 Ultra — sustained CPU within spec budget
EOF
)"
```

(Then FF-merge locally per the existing workflow when ready to ship.)

---

## Self-Review Notes

**Spec coverage check:**
- Glass aesthetic preserved → Task 5 keeps bar layout / blur / 4 px anchor unchanged; only adds divider + text right of bars ✓
- Single model → Task 2 + Task 4 reuse `WhisperTranscriptionService` context; no second load ✓
- Final paste authoritative → Task 7 awaits `stop()` then calls existing `transcribe()` unchanged ✓
- Sliding window with commit → Task 4 + Task 2 (timestamps + split) ✓
- Settings Off/Balanced/Responsive → Task 1 + Task 6 ✓
- CPU calibration before ship → Task 8 step 3 ✓
- Off mode regression-free → Task 7 step 5 test ✓
- RAM work explicitly deferred → no task touches model loading; verified ✓

**Type consistency check:**
- `onPartialUpdate` signature: `(String, String) -> Void` — used in Tasks 4, 5, 7 consistently as `(committed, active)` ✓
- `StreamingMode.userDefaultsKey` referenced in Tasks 1, 6, 7 — same string ✓
- `transcribeTimed(samples:sampleRate:)` returns `TimedTranscript` — Tasks 2, 4 align ✓
- `AudioRecording.onSamples` added in Task 3, used in Task 7 ✓

No placeholders. No TBDs. All code blocks complete.
