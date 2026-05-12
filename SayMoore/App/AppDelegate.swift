import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appState = AppState()
    private let recorder = AudioRecorder()
    private lazy var paste = PasteService(
        pasteboard: NSPasteboardAdapter(),
        keyboard: CGEventKeyboardAdapter(),
        frontmost: NSWorkspaceFrontmostAdapter()
    )
    private var transcription: TranscriptionService?
    private var coordinator: PipelineCoordinator?
    private let hotkey = HotkeyService()
    private var menuBar: MenuBarController?
    private var bootstrap: ModelBootstrap?
    private var bootstrapWindow: ModelDownloadWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("SayMoore launched (v\(Bundle.main.shortVersion, privacy: .public))")
        NSApp.setActivationPolicy(.accessory)
        menuBar = MenuBarController(appState: appState)

        Task { @MainActor in
            await bootstrapModelThenStart()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey.stop()
        Log.app.info("SayMoore terminating")
    }

    // MARK: - Bootstrap

    private func bootstrapModelThenStart() async {
        let downloader = ModelDownloader(
            remoteURL: WhisperModel.remoteURL,
            destinationURL: WhisperModel.defaultDestinationURL,
            expectedSHA256: WhisperModel.expectedSHA256
        )
        let boot = ModelBootstrap(downloader: downloader)
        self.bootstrap = boot

        // If already complete, skip UI entirely.
        if (try? downloader.currentStatus()) == .complete {
            await boot.run()
            startPipeline()
            return
        }

        let win = ModelDownloadWindow(bootstrap: boot)
        self.bootstrapWindow = win

        // Kick off the run and the window concurrently; window awaits .ready.
        let runTask = Task { @MainActor in await boot.run() }
        await win.present { [weak self] in
            // Retry: re-run bootstrap inside the same window.
            Task { @MainActor in await self?.bootstrap?.run() }
        }
        _ = await runTask.value

        win.close()
        self.bootstrapWindow = nil
        startPipeline()
    }

    private func startPipeline() {
        let modelPath = WhisperModel.defaultDestinationURL.path
        let svc = WhisperTranscriptionService(modelPath: modelPath)
        self.transcription = svc

        let ollama = OllamaService()
        let cleanup = CleanupService(client: ollama, presets: PresetStore())
        let notifier = NotificationCenterAdapter.shared

        let coord = PipelineCoordinator(
            appState: appState,
            recorder: recorder,
            transcription: svc,
            paste: paste,
            cleanup: cleanup,
            recordingsDir: Self.recordingsDirIfPossible(),
            onFallback: { error in notifier.notify(error) }
        )
        self.coordinator = coord

        // Fire-and-forget Ollama health probe.
        Task.detached {
            do {
                let tags = try await ollama.tags()
                Log.cleanup.info("ollama up, models=\(tags.joined(separator: ","), privacy: .public)")
                if !tags.contains(where: { $0.hasPrefix("qwen2.5:7b-instruct") }) {
                    await MainActor.run { notifier.notify(.ollamaModelNotPulled) }
                }
            } catch let e as SayMooreError {
                await MainActor.run { notifier.notify(e) }
            } catch {
                Log.cleanup.error("ollama probe error: \(String(describing: error), privacy: .public)")
            }
        }

        hotkey.isRecording = { [weak self] in
            self?.appState.state == .recording
        }
        hotkey.onToggle = { [weak self] bundleID in
            self?.coordinator?.toggle(bundleID: bundleID)
        }
        hotkey.onCancel = { [weak self] in
            self?.coordinator?.cancel()
        }
        hotkey.start()
        Log.app.info("pipeline armed")
    }

    private static func recordingsDirIfPossible() -> URL? {
        let url = RecordingPaths.defaultDirectory()
        return (try? RecordingPaths.ensureDirectory(at: url))
    }
}

private extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
    }
}
