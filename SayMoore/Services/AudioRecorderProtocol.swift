import Foundation

@MainActor
protocol AudioRecording: AnyObject {
    var isRecording: Bool { get }
    func start() throws
    func stop() throws -> [Float]
    func cancel()
}

extension AudioRecorder: AudioRecording {}
