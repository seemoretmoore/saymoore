import XCTest
@testable import SayMoore

final class VADBackendTests: XCTestCase {

    // MARK: - FakeVADBackend

    func testFakeReturnsCannedSequenceInOrder() throws {
        let backend = FakeVADBackend(canned: [.silence, .speech, .silence])
        let frame = Array(repeating: Float(0), count: SileroFrameSamples)
        XCTAssertEqual(try backend.classify(frame), .silence)
        XCTAssertEqual(try backend.classify(frame), .speech)
        XCTAssertEqual(try backend.classify(frame), .silence)
    }

    func testFakeLoopsWhenExhausted() throws {
        let backend = FakeVADBackend(canned: [.silence, .speech])
        let frame = Array(repeating: Float(0), count: SileroFrameSamples)
        XCTAssertEqual(try backend.classify(frame), .silence)
        XCTAssertEqual(try backend.classify(frame), .speech)
        XCTAssertEqual(try backend.classify(frame), .silence) // looped
        XCTAssertEqual(try backend.classify(frame), .speech)
    }

    func testFakeResetReturnsToBeginning() throws {
        let backend = FakeVADBackend(canned: [.silence, .speech])
        let frame = Array(repeating: Float(0), count: SileroFrameSamples)
        _ = try backend.classify(frame)
        _ = try backend.classify(frame)
        backend.reset()
        XCTAssertEqual(try backend.classify(frame), .silence)
    }

    func testFakeCountsClassifyCalls() throws {
        let backend = FakeVADBackend(canned: [.silence])
        let frame = Array(repeating: Float(0), count: SileroFrameSamples)
        for _ in 0..<5 { _ = try backend.classify(frame) }
        XCTAssertEqual(backend.classifyCalls, 5)
    }

    // MARK: - SileroVADBackend

    private func makeSilero() throws -> SileroVADBackend {
        let bundle = Bundle(for: type(of: self))
        let hostBundle = Bundle.main
        let path =
            hostBundle.path(forResource: "silero_vad", ofType: "onnx") ??
            bundle.path(forResource: "silero_vad", ofType: "onnx")
        guard let path else {
            throw XCTSkip("silero_vad.onnx not bundled — run scripts/setup-silero.sh and regen project to enable Silero tests locally")
        }
        return try SileroVADBackend(modelPath: path)
    }

    func testSileroRejectsWrongFrameSize() throws {
        let backend = try makeSilero()
        let short = Array(repeating: Float(0), count: 256)
        XCTAssertThrowsError(try backend.classify(short)) { error in
            guard case SileroVADError.frameSizeMismatch(let got, let expected) = error else {
                XCTFail("expected frameSizeMismatch, got \(error)")
                return
            }
            XCTAssertEqual(got, 256)
            XCTAssertEqual(expected, SileroFrameSamples)
        }
    }

    func testSileroClassifiesZeroSignalAsSilence() throws {
        let backend = try makeSilero()
        let silence = Array(repeating: Float(0), count: SileroFrameSamples)
        // Silero usually needs a few frames to settle; classify several and
        // assert that the *eventual* state is silence (the last few frames).
        var classifications: [VADFrameClass] = []
        for _ in 0..<20 {
            classifications.append(try backend.classify(silence))
        }
        let tail = classifications.suffix(5)
        XCTAssertTrue(tail.allSatisfy { $0 == .silence }, "expected sustained silence after warmup, got \(classifications)")
    }

    func testSileroRejectsBroadbandNoiseAsNonSpeech() throws {
        // Silero v5 is trained specifically to detect human speech, not just
        // "energy". White noise should NOT trigger speech classification — this
        // is the property that makes Silero better than a simple RMS threshold.
        let backend = try makeSilero()
        var rng = SystemRandomNumberGenerator()
        let noise: [Float] = (0..<SileroFrameSamples).map { _ in
            Float.random(in: -0.5...0.5, using: &rng)
        }

        var speechCount = 0
        for _ in 0..<30 {
            if try backend.classify(noise) == .speech { speechCount += 1 }
        }
        XCTAssertEqual(speechCount, 0, "broadband white noise should not be classified as speech (got \(speechCount)/30 frames)")
    }

    func testSileroResetClearsState() throws {
        let backend = try makeSilero()
        let silence = Array(repeating: Float(0), count: SileroFrameSamples)
        for _ in 0..<10 { _ = try backend.classify(silence) }
        // Reset and confirm it still runs without throwing.
        backend.reset()
        _ = try backend.classify(silence)
    }

    func testSileroInitRejectsMissingModel() {
        XCTAssertThrowsError(try SileroVADBackend(modelPath: "/nonexistent/silero.onnx")) { error in
            guard case SileroVADError.modelMissing = error else {
                XCTFail("expected modelMissing, got \(error)")
                return
            }
        }
    }
}
