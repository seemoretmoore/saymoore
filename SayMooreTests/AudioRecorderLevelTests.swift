import XCTest
@testable import SayMoore

final class AudioRecorderLevelTests: XCTestCase {
    func testSilenceIsZero() {
        let samples = Array(repeating: Float(0), count: 1024)
        XCTAssertEqual(AudioRecorder.computeNormalizedLevel(samples), 0, accuracy: 0.001)
    }

    func testEmptyBufferIsZero() {
        XCTAssertEqual(AudioRecorder.computeNormalizedLevel([]), 0, accuracy: 0.001)
    }

    func testFullScaleSineIsNearOne() {
        let n = 1024
        var samples = [Float](repeating: 0, count: n)
        for i in 0..<n {
            samples[i] = sinf(.pi * 2 * Float(i) / 32)
        }
        // RMS of a full-scale sine = 1/sqrt(2) ≈ 0.707 → -3.01 dBFS → ≈0.95 normalized.
        let level = AudioRecorder.computeNormalizedLevel(samples)
        XCTAssertGreaterThan(level, 0.9)
        XCTAssertLessThanOrEqual(level, 1.0)
    }

    func testMidLevelSineIsAroundHalf() {
        // Target -30 dBFS RMS → amplitude = 0.0316 * sqrt(2) ≈ 0.0447.
        let n = 1024
        var samples = [Float](repeating: 0, count: n)
        let amplitude = Float(0.0316) * sqrtf(2)
        for i in 0..<n {
            samples[i] = amplitude * sinf(.pi * 2 * Float(i) / 32)
        }
        // -30 dBFS → (-30 + 60) / 60 = 0.5
        XCTAssertEqual(AudioRecorder.computeNormalizedLevel(samples), 0.5, accuracy: 0.05)
    }

    func testFloorBelowNoiseGate() {
        // -90 dBFS is below the -60 dBFS window; should clamp to 0.
        let samples = Array(repeating: Float(1e-5), count: 1024)
        XCTAssertEqual(AudioRecorder.computeNormalizedLevel(samples), 0, accuracy: 0.001)
    }
}
