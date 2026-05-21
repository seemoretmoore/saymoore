import AppKit
import Sparkle

@MainActor
final class UpdaterService: NSObject {
    static let shared = UpdaterService()

    private let controller: SPUStandardUpdaterController

    override init() {
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        controller.checkForUpdates(sender)
    }
}
