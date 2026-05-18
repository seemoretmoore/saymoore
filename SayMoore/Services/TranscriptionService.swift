import Foundation

protocol TranscriptionService: Sendable {
    /// Transcribe 16 kHz mono float samples.
    func transcribe(samples: [Float], sampleRate: Int) async throws -> Transcript
}

#if canImport(whisper)
import whisper

final class WhisperTranscriptionService: TranscriptionService, @unchecked Sendable {
    private let modelPath: String
    private let serial = DispatchQueue(label: "com.seemoretmoore.saymoore.whisper", qos: .userInitiated)
    private var ctx: OpaquePointer?
    // Guards ctx and wasFreed; serial queue serializes work but deinit may race from any thread.
    private let lock = NSLock()
    private var wasFreed = false

    init(modelPath: String) {
        self.modelPath = modelPath
    }

    deinit {
        // Serialize through the work queue: the strong-self capture in transcribe's
        // serial.async block ensures deinit cannot fire from within the queue, so this
        // sync hop is safe and guarantees no in-flight whisper_full uses freed ctx.
        serial.sync {
            lock.lock()
            wasFreed = true
            if let ctx { whisper_free(ctx); self.ctx = nil }
            lock.unlock()
            Log.transcribe.debug("WhisperTranscriptionService freed ctx")
        }
    }

    func transcribe(samples: [Float], sampleRate: Int) async throws -> Transcript {
        precondition(sampleRate == 16_000, "WhisperTranscriptionService requires 16kHz")
        return try await withCheckedThrowingContinuation { cont in
            serial.async { [self] in
                do {
                    let result = try self.transcribeSync(samples: samples)
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func transcribeSync(samples: [Float]) throws -> Transcript {
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
        var segments: [TranscriptSegment] = []
        segments.reserveCapacity(Int(nSegments))
        for i in 0..<nSegments {
            let cstr = whisper_full_get_segment_text(localCtx, i)
            let text = cstr.map { String(cString: $0) } ?? ""
            let prob = whisper_full_get_segment_no_speech_prob(localCtx, i)
            segments.append(TranscriptSegment(text: text, noSpeechProb: prob))
        }
        return Transcript.fromSegments(segments)
    }

    enum WhisperBridgeError: Error {
        case modelInitFailed
        case fullFailed(status: Int32)
    }
}
#else
final class WhisperTranscriptionService: TranscriptionService {
    private let modelPath: String
    init(modelPath: String) { self.modelPath = modelPath }
    func transcribe(samples: [Float], sampleRate: Int) async throws -> Transcript {
        Log.transcribe.error("whisper.xcframework not linked — run scripts/setup-whisper.sh and re-add to project.yml")
        throw SayMooreError.modelMissing
    }
}
#endif

final class FakeTranscriptionService: TranscriptionService, @unchecked Sendable {
    var nextResult: Result<Transcript, Error> = .success(Transcript(text: "fake transcript", averageNoSpeechProb: 0))
    private(set) var calls = 0
    func transcribe(samples: [Float], sampleRate: Int) async throws -> Transcript {
        calls += 1
        return try nextResult.get()
    }
}
