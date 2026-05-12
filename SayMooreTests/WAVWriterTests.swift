import XCTest
@testable import SayMoore

final class WAVWriterTests: XCTestCase {
    func testHeaderRIFFAndWAVE() {
        let data = WAVWriter.encode(samples: [0.0, 0.1, -0.1], sampleRate: 16_000)
        XCTAssertGreaterThan(data.count, 44)
        XCTAssertEqual(String(data: data.subdata(in: 0..<4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data.subdata(in: 8..<12), encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: data.subdata(in: 12..<16), encoding: .ascii), "fmt ")
        XCTAssertEqual(String(data: data.subdata(in: 36..<40), encoding: .ascii), "data")
    }

    func testFmtChunkDescribes16kMono16Bit() {
        let data = WAVWriter.encode(samples: [0.0], sampleRate: 16_000)
        let audioFormat = data.uint16LE(at: 20)
        let numChannels = data.uint16LE(at: 22)
        let sampleRate  = data.uint32LE(at: 24)
        let byteRate    = data.uint32LE(at: 28)
        let blockAlign  = data.uint16LE(at: 32)
        let bitsPer     = data.uint16LE(at: 34)

        XCTAssertEqual(audioFormat, 1)            // PCM
        XCTAssertEqual(numChannels, 1)
        XCTAssertEqual(sampleRate,  16_000)
        XCTAssertEqual(bitsPer,     16)
        XCTAssertEqual(blockAlign,  2)            // 1ch * 16/8
        XCTAssertEqual(byteRate,    16_000 * 2)
    }

    func testDataChunkSizeMatchesSampleCount() {
        let samples: [Float] = Array(repeating: 0.0, count: 1000)
        let data = WAVWriter.encode(samples: samples, sampleRate: 16_000)
        let dataSize = data.uint32LE(at: 40)
        XCTAssertEqual(dataSize, UInt32(samples.count * 2))
        XCTAssertEqual(data.count, 44 + samples.count * 2)
    }

    func testRIFFSizeIsTotalMinusEight() {
        let samples: [Float] = Array(repeating: 0.0, count: 256)
        let data = WAVWriter.encode(samples: samples, sampleRate: 16_000)
        let riffSize = data.uint32LE(at: 4)
        XCTAssertEqual(riffSize, UInt32(data.count - 8))
    }

    func testFloatToInt16ScalingAndClamp() {
        let data = WAVWriter.encode(samples: [0.0, 1.0, -1.0, 2.0, -2.0], sampleRate: 16_000)
        let s0 = data.int16LE(at: 44)
        let s1 = data.int16LE(at: 46)
        let s2 = data.int16LE(at: 48)
        let s3 = data.int16LE(at: 50)
        let s4 = data.int16LE(at: 52)
        XCTAssertEqual(s0, 0)
        XCTAssertEqual(s1, Int16.max)
        XCTAssertEqual(s2, Int16.min + 1) // -32767 (one-sided symmetric scaling)
        XCTAssertEqual(s3, Int16.max)     // clamped
        XCTAssertEqual(s4, Int16.min + 1) // clamped
    }
}

private extension Data {
    func uint16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }
    func uint32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
    func int16LE(at offset: Int) -> Int16 {
        Int16(bitPattern: uint16LE(at: offset))
    }
}
