import Foundation

enum WAVWriter {
    static func encode(samples: [Float], sampleRate: Int) -> Data {
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let bytesPerSample = Int(bitsPerSample / 8)
        let blockAlign = UInt16(Int(channels) * bytesPerSample)
        let byteRate = UInt32(sampleRate * Int(blockAlign))
        let dataSize = UInt32(samples.count * bytesPerSample)
        let riffSize = UInt32(36 + Int(dataSize))

        var d = Data(capacity: 44 + Int(dataSize))
        d.append(contentsOf: Array("RIFF".utf8))
        d.appendLE(riffSize)
        d.append(contentsOf: Array("WAVE".utf8))

        d.append(contentsOf: Array("fmt ".utf8))
        d.appendLE(UInt32(16))           // fmt chunk size
        d.appendLE(UInt16(1))            // PCM
        d.appendLE(channels)
        d.appendLE(UInt32(sampleRate))
        d.appendLE(byteRate)
        d.appendLE(blockAlign)
        d.appendLE(bitsPerSample)

        d.append(contentsOf: Array("data".utf8))
        d.appendLE(dataSize)

        d.reserveCapacity(d.count + Int(dataSize))
        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            let scaled = Int32((clamped * 32767.0).rounded())
            let int16 = Int16(max(Int32(Int16.min) + 1, min(Int32(Int16.max), scaled)))
            d.appendLE(UInt16(bitPattern: int16))
        }
        return d
    }
}

private extension Data {
    mutating func appendLE(_ v: UInt16) {
        append(UInt8(v & 0xff))
        append(UInt8((v >> 8) & 0xff))
    }
    mutating func appendLE(_ v: UInt32) {
        append(UInt8(v & 0xff))
        append(UInt8((v >> 8) & 0xff))
        append(UInt8((v >> 16) & 0xff))
        append(UInt8((v >> 24) & 0xff))
    }
}
