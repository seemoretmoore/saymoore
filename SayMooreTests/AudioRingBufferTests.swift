import XCTest
@testable import SayMoore

final class AudioRingBufferTests: XCTestCase {
    func testWriteThenReadReturnsSameSamples() {
        let rb = AudioRingBuffer(capacity: 1024)
        let input: [Float] = (0..<512).map { Float($0) }
        let written = rb.write(input)
        XCTAssertEqual(written, 512)

        let drained = rb.drainAll()
        XCTAssertEqual(drained, input)
    }

    func testWrapAroundPreservesOrder() {
        let rb = AudioRingBuffer(capacity: 8)
        XCTAssertEqual(rb.write([1, 2, 3, 4, 5, 6]), 6)
        _ = rb.drainAll()                              // empties
        XCTAssertEqual(rb.write([7, 8, 9, 10, 11]), 5) // wraps internally
        XCTAssertEqual(rb.drainAll(), [7, 8, 9, 10, 11])
    }

    func testWriteRejectsOverflow() {
        let rb = AudioRingBuffer(capacity: 4)
        XCTAssertEqual(rb.write([1, 2, 3]), 3)
        // Only 1 slot left; writing 3 more should accept 1 and drop 2.
        XCTAssertEqual(rb.write([4, 5, 6]), 1)
        XCTAssertEqual(rb.drainAll(), [1, 2, 3, 4])
    }

    func testDrainAllEmptiesBuffer() {
        let rb = AudioRingBuffer(capacity: 16)
        _ = rb.write([1, 2, 3])
        _ = rb.drainAll()
        XCTAssertEqual(rb.drainAll(), [])
    }

    // C2: overflow flag set when write exceeds capacity
    func testOverflowFlagSetOnExceedCapacity() {
        let capacity = 100
        let rb = AudioRingBuffer(capacity: capacity)
        XCTAssertFalse(rb.overflowed)
        // Write capacity + 100 samples in one call
        let samples = [Float](repeating: 1.0, count: capacity + 100)
        _ = rb.write(samples)
        XCTAssertTrue(rb.overflowed, "overflowed should be true after write exceeds capacity")
        // Only capacity samples buffered
        let drained = rb.drainAll()
        XCTAssertEqual(drained.count, capacity)
    }

    // C2: reset() clears overflow flag
    func testResetClearsOverflowFlag() {
        let rb = AudioRingBuffer(capacity: 4)
        _ = rb.write([Float](repeating: 0, count: 10))
        XCTAssertTrue(rb.overflowed)
        rb.reset()
        XCTAssertFalse(rb.overflowed)
        XCTAssertEqual(rb.drainAll(), [])
    }

    // C2: no overflow flag when write fits exactly
    func testNoOverflowFlagWhenWriteFits() {
        let rb = AudioRingBuffer(capacity: 8)
        _ = rb.write([Float](repeating: 0, count: 8))
        XCTAssertFalse(rb.overflowed)
    }
}
