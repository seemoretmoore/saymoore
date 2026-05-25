import Foundation

@MainActor
protocol AudioRecording: AnyObject {
    var isRecording: Bool { get }
    /// Optional VAD service attached by the coordinator. The recorder feeds
    /// converted PCM to it from the tap callback when non-nil and resets it on start().
    var vadService: VADService? { get set }
    /// Optional tap that forwards converted 16 kHz mono samples to a streaming
    /// consumer (StreamingTranscriber). Set by PipelineCoordinator when the
    /// streaming-partials mode != .off, cleared on stop/cancel.
    var onSamples: (@Sendable ([Float]) -> Void)? { get set }
    func start() throws
    func stop() throws -> [Float]
    func cancel()
}

extension AudioRecorder: AudioRecording {}
