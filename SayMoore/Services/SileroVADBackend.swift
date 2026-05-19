import Foundation
import OnnxRuntimeBindings

/// Frame width for Silero VAD v5 at 16 kHz: 512 samples = 32 ms.
let SileroFrameSamples = 512
/// Speech-probability threshold. Above → speech, below → silence.
private let SileroSpeechThreshold: Float = 0.5
/// LSTM hidden-state shape for Silero v5: 2 layers × batch 1 × 128 dim.
private let SileroStateShape: [NSNumber] = [2, 1, 128]
private let SileroStateElementCount = 2 * 1 * 128
private let SileroInputShape: [NSNumber] = [1, NSNumber(value: SileroFrameSamples)]
private let SileroSampleRate: Int64 = 16_000

/// Errors raised by SileroVADBackend at init or per-frame.
enum SileroVADError: Error, Equatable {
    case modelMissing(path: String)
    case sessionInitFailed(underlying: String)
    case frameSizeMismatch(got: Int, expected: Int)
    case inferenceFailed(underlying: String)
    case outputMissing(name: String)
}

/// Production VAD backend using Silero VAD v5 via ONNX Runtime.
/// The model is stateful: an LSTM hidden state is threaded across frames via the
/// `state` input/output. Always create a fresh instance (or call `reset()`) per
/// recording — stale state from a prior recording will degrade accuracy.
///
/// Concurrency: a serial `DispatchQueue` guards the ORT session, matching the
/// pattern used by `WhisperTranscriptionService`. The class is `@unchecked Sendable`
/// because the underlying ORT objects are not Swift-Sendable but are only touched
/// from this queue.
final class SileroVADBackend: VADBackend, @unchecked Sendable {
    private let env: ORTEnv
    private let session: ORTSession
    private let serial = DispatchQueue(label: "com.seemoretmoore.saymoore.silero-vad", qos: .userInitiated)
    private let lock = NSLock()
    private var state: [Float] = Array(repeating: 0, count: SileroStateElementCount)

    /// Load the Silero ONNX model from disk.
    /// - Parameter modelPath: absolute path to `silero_vad.onnx` (typically
    ///   `Bundle.main.path(forResource: "silero_vad", ofType: "onnx")`).
    init(modelPath: String) throws {
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw SileroVADError.modelMissing(path: modelPath)
        }
        do {
            self.env = try ORTEnv(loggingLevel: .warning)
            let opts = try ORTSessionOptions()
            try opts.setIntraOpNumThreads(1)
            self.session = try ORTSession(env: env, modelPath: modelPath, sessionOptions: opts)
        } catch {
            throw SileroVADError.sessionInitFailed(underlying: String(describing: error))
        }
    }

    func classify(_ frame: [Float]) throws -> VADFrameClass {
        guard frame.count == SileroFrameSamples else {
            throw SileroVADError.frameSizeMismatch(got: frame.count, expected: SileroFrameSamples)
        }

        // serial.sync hop: cheap, and matches the Whisper pattern. The audio thread
        // never calls this directly — VADService drains a queue on a worker thread.
        return try serial.sync {
            try runInference(frame: frame)
        }
    }

    func reset() {
        lock.lock()
        state = Array(repeating: 0, count: SileroStateElementCount)
        lock.unlock()
    }

    private func runInference(frame: [Float]) throws -> VADFrameClass {
        // input: float32 [1, 512]
        let inputData = frame.withUnsafeBufferPointer { buf in
            NSMutableData(bytes: buf.baseAddress!, length: buf.count * MemoryLayout<Float>.size)
        }
        let inputValue: ORTValue
        let stateValue: ORTValue
        let srValue: ORTValue
        do {
            inputValue = try ORTValue(
                tensorData: inputData,
                elementType: .float,
                shape: SileroInputShape
            )

            lock.lock()
            let stateSnapshot = state
            lock.unlock()
            let stateData = stateSnapshot.withUnsafeBufferPointer { buf in
                NSMutableData(bytes: buf.baseAddress!, length: buf.count * MemoryLayout<Float>.size)
            }
            stateValue = try ORTValue(
                tensorData: stateData,
                elementType: .float,
                shape: SileroStateShape
            )

            var sr: Int64 = SileroSampleRate
            let srData = withUnsafeBytes(of: &sr) { NSMutableData(bytes: $0.baseAddress!, length: $0.count) }
            srValue = try ORTValue(
                tensorData: srData,
                elementType: .int64,
                shape: [1]
            )
        } catch {
            throw SileroVADError.inferenceFailed(underlying: String(describing: error))
        }

        let inputs: [String: ORTValue] = [
            "input": inputValue,
            "state": stateValue,
            "sr": srValue,
        ]
        let outputNames: Set<String> = ["output", "stateN"]

        let outputs: [String: ORTValue]
        do {
            outputs = try session.run(
                withInputs: inputs,
                outputNames: outputNames,
                runOptions: nil
            )
        } catch {
            throw SileroVADError.inferenceFailed(underlying: String(describing: error))
        }

        guard let outputValue = outputs["output"] else {
            throw SileroVADError.outputMissing(name: "output")
        }
        guard let stateNValue = outputs["stateN"] else {
            throw SileroVADError.outputMissing(name: "stateN")
        }

        // Read speech probability and updated state.
        let outputData: NSMutableData
        let stateNData: NSMutableData
        do {
            outputData = try outputValue.tensorData() as NSMutableData
            stateNData = try stateNValue.tensorData() as NSMutableData
        } catch {
            throw SileroVADError.inferenceFailed(underlying: String(describing: error))
        }

        let prob: Float = outputData.bytes.assumingMemoryBound(to: Float.self).pointee

        // Persist the updated LSTM state for the next call.
        let stateNFloats = stateNData.bytes.assumingMemoryBound(to: Float.self)
        lock.lock()
        for i in 0..<SileroStateElementCount {
            state[i] = stateNFloats[i]
        }
        lock.unlock()

        return prob >= SileroSpeechThreshold ? .speech : .silence
    }
}
