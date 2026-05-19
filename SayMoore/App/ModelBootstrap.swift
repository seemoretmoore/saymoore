import Foundation
import SwiftUI

@MainActor
final class ModelBootstrap: ObservableObject {
    enum Phase: Equatable {
        case checking
        case downloading(progress: Double)
        case verifying
        case ready
        case failed(SayMooreError)
    }

    @Published private(set) var phase: Phase = .checking

    private let downloader: ModelDownloading

    init(downloader: ModelDownloading) {
        self.downloader = downloader
    }

    func run() async {
        phase = .checking
        await downloader.verifyExistingIfPossible()
        let status: ModelDownloaderStatus
        do {
            status = try downloader.currentStatus()
        } catch {
            Log.model.error("currentStatus failed: \(String(describing: error), privacy: .public)")
            phase = .failed(.modelMissing)
            return
        }

        if case .complete = status {
            Log.model.info("model already present — bootstrap done")
            phase = .ready
            return
        }

        phase = .downloading(progress: 0)
        Log.model.info("model status=\(String(describing: status), privacy: .public) — starting download")

        do {
            try await downloader.download { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if case .downloading = self.phase {
                        self.phase = .downloading(progress: progress)
                    }
                }
            }
            phase = .verifying
            phase = .ready
            Log.model.info("bootstrap ready")
        } catch let err as SayMooreError {
            Log.model.error("bootstrap failed: \(String(describing: err), privacy: .public)")
            if err == .modelCorrupted {
                // Slice 9 Task C3: surface corruption to the menu bar so the
                // persistent badge appears alongside the ModelDownloadWindow
                // retry path. ModelDownloader has already scrubbed the bad
                // file + sentinel, so the existing retry button restarts
                // the download from byte 0.
                NotificationCoordinator.shared.notify(.modelCorrupted)
            }
            phase = .failed(err)
        } catch {
            Log.model.error("bootstrap failed: \(String(describing: error), privacy: .public)")
            phase = .failed(.modelMissing)
        }
    }
}
