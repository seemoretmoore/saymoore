import Foundation

final class AudioRingBuffer: @unchecked Sendable {
    let capacity: Int
    private let storage: UnsafeMutableBufferPointer<Float>
    private let lock = NSLock()
    private var head = 0
    private var tail = 0
    private var count = 0
    private(set) var overflowed: Bool = false

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        let p = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        p.initialize(repeating: 0, count: capacity)
        self.storage = UnsafeMutableBufferPointer(start: p, count: capacity)
    }

    deinit {
        storage.baseAddress?.deinitialize(count: capacity)
        storage.deallocate()
    }

    @discardableResult
    func write(_ samples: [Float]) -> Int {
        lock.lock(); defer { lock.unlock() }
        let canWrite = min(samples.count, capacity - count)
        if samples.count > canWrite { overflowed = true }
        for i in 0..<canWrite {
            storage[(head + i) % capacity] = samples[i]
        }
        head = (head + canWrite) % capacity
        count += canWrite
        return canWrite
    }

    @discardableResult
    func write(_ buffer: UnsafeBufferPointer<Float>) -> Int {
        lock.lock(); defer { lock.unlock() }
        let canWrite = min(buffer.count, capacity - count)
        if buffer.count > canWrite { overflowed = true }
        for i in 0..<canWrite {
            storage[(head + i) % capacity] = buffer[i]
        }
        head = (head + canWrite) % capacity
        count += canWrite
        return canWrite
    }

    func drainAll() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        var out = [Float]()
        out.reserveCapacity(count)
        for i in 0..<count {
            out.append(storage[(tail + i) % capacity])
        }
        tail = head
        count = 0
        return out
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        head = 0
        tail = 0
        count = 0
        overflowed = false
    }
}
