import XCTest
@testable import SayMoore

final class ModelBootstrapTests: XCTestCase {

    private final class FakeDownloader: ModelDownloading, @unchecked Sendable {
        var status: ModelDownloaderStatus = .missing
        var statusError: Error?
        var downloadError: Error?
        var progressTicks: [Double] = [0.25, 0.5, 1.0]

        func currentStatus() throws -> ModelDownloaderStatus {
            if let e = statusError { throw e }
            return status
        }

        func download(progress: @escaping @Sendable (Double) -> Void) async throws {
            for p in progressTicks {
                progress(p)
                await Task.yield()
            }
            if let e = downloadError { throw e }
        }

        var verifyExistingCalls = 0
        var onVerifyExisting: (@Sendable () -> Void)?
        func verifyExistingIfPossible() async {
            verifyExistingCalls += 1
            onVerifyExisting?()
        }
    }

    @MainActor
    func testRunCallsVerifyExistingBeforeStatus() async {
        let fake = FakeDownloader()
        fake.status = .complete
        let order = OrderRecorder()
        fake.onVerifyExisting = { order.record("verify") }
        let boot = ModelBootstrap(downloader: fake)
        await boot.run()
        XCTAssertEqual(fake.verifyExistingCalls, 1)
        XCTAssertEqual(order.events.first, "verify")
    }

    private final class OrderRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var events: [String] = []
        func record(_ s: String) { lock.lock(); events.append(s); lock.unlock() }
    }

    @MainActor
    func testCompleteStatusSkipsDownloadAndReachesReady() async {
        let fake = FakeDownloader()
        fake.status = .complete
        let boot = ModelBootstrap(downloader: fake)
        await boot.run()
        XCTAssertEqual(boot.phase, .ready)
    }

    @MainActor
    func testMissingStatusDrivesDownloadThenReady() async {
        let fake = FakeDownloader()
        fake.status = .missing
        let boot = ModelBootstrap(downloader: fake)
        await boot.run()
        XCTAssertEqual(boot.phase, .ready)
    }

    @MainActor
    func testDownloadFailureBecomesFailedPhase() async {
        let fake = FakeDownloader()
        fake.status = .missing
        fake.downloadError = SayMooreError.modelCorrupted
        let boot = ModelBootstrap(downloader: fake)
        await boot.run()
        XCTAssertEqual(boot.phase, .failed(.modelCorrupted))
    }

    @MainActor
    func testCurrentStatusThrowFallsToFailed() async {
        struct Boom: Error {}
        let fake = FakeDownloader()
        fake.statusError = Boom()
        let boot = ModelBootstrap(downloader: fake)
        await boot.run()
        XCTAssertEqual(boot.phase, .failed(.modelMissing))
    }
}

