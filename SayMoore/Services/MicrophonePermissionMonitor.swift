import AVFoundation
import Foundation

@MainActor
final class MicrophonePermissionMonitor {
    private let poll: Duration
    private let statusProvider: () -> AVAuthorizationStatus
    private let onRevoked: () -> Void
    private var task: Task<Void, Never>?
    private var lastStatus: AVAuthorizationStatus?

    init(
        poll: Duration = .seconds(2),
        statusProvider: @escaping () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .audio) },
        onRevoked: @escaping () -> Void
    ) {
        self.poll = poll
        self.statusProvider = statusProvider
        self.onRevoked = onRevoked
    }

    func start() {
        stop()
        let pollLocal = self.poll
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await MainActor.run {
                    let s = self.statusProvider()
                    if self.lastStatus == .authorized && s != .authorized {
                        self.onRevoked()
                    }
                    self.lastStatus = s
                }
                try? await Task.sleep(for: pollLocal)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
