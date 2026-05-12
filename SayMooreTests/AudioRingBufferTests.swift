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
}
