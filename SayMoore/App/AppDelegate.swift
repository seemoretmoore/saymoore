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
    private let presets = PresetStore()
    private var presetWatcher: PresetWatcher?
    private var menuBar: MenuBarController?
    private var bootstrap: ModelBootstrap?
    private var bootstrapWindow: ModelDownloadWindow?
    private let audioFeedback = AudioFeedbackService()
    /// Set to true when the Ollama endpoint trust probe returns `.untrustedEndpoint`.
    /// PipelineCoordinator checks this flag before starting a recording.
    var ollamaEndpointBlocked = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("SayMoore launched (v\(Bundle.main.shortVersion, privacy: .public))")
        Task.detached(priority: .utility) {
            var code: SecCode?
            guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return }
            var staticCode: SecStaticCode?
            guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return }
            var infoCF: CFDictionary?
            guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &infoCF) == errSecSuccess,
                  let info = infoCF as? [String: Any] else { return }
            let ident = info[kSecCodeInfoIdentifier as String] as? String ?? "?"
            let flags = info[kSecCodeInfoFlags as String] as? UInt32 ?? 0
            let cdhash = (info[kSecCodeInfoUnique as String] as? Data)?.map { String(format: "%02x", $0) }.joined() ?? "?"
            Log.app.info("signing: ident=\(ident, privacy: .public) flags=0x\(String(flags, radix: 16), privacy: .public) cdhash=\(cdhash, privacy: .public)")
        }
        NSApp.setActivationPolicy(.accessory)
        menuBar = MenuBarController(appState: appState, presets: presets)

        #if !DEBUG
        // Belt-and-braces: clear any orphan raw-WAVs left by a prior Debug
        // session on this machine. Release builds never write to this dir
        // (persistRawWAV is compile-time-stripped) so it should stay empty.
        RecordingPaths.purgeAll(in: RecordingPaths.defaultDirectory())
        #endif

        Task {
            await bootstrapModelThenStart()
        }

        // M2: Ollama endpoint trust probe — runs concurrently with bootstrap.
        Task {
            let result = await OllamaTrustProbe().probe()
            switch result {
            case .trusted:
                break
            case .untrustedEndpoint:
                ollamaEndpointBlocked = true
                coordinator?.blocked = true
                NotificationCenterAdapter.shared.notify(.ollamaEndpointUntrusted)
                Log.app.error("ollama endpoint trust probe: untrusted — dictation blocked")
            case .probeFailed(let error):
                Log.app.error("ollama endpoint trust probe failed (non-fatal): \(String(describing: error), privacy: .public)")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey.stop()
        presetWatcher?.stop()
        Log.app.info("SayMoore terminating")
    }

    private func reloadPresetsAndNotifyOnFailure() {
        do {
            try presets.reload()
            Log.presets.info("presets.json reloaded")
        } catch {
            Log.presets.error("presets reload failed: \(String(describing: error), privacy: .public)")
            // Q1: method is already @MainActor — no inner Task needed.
            let body = Self.bannerCopy(for: error)
            NotificationCenterAdapter.shared.notify(title: "Preset error", body: body)
        }
    }

    /// M6: Map each `PresetStoreError` discriminant to concise user-actionable copy.
    /// Extracted as a static function for testability.
    nonisolated static func bannerCopy(for error: Error) -> String {
        guard let e = error as? PresetStoreError else {
            return "presets.json error — using last-good config."
        }
        switch e {
        case .fileUnreadable:
            return "Couldn't read presets.json — using last-good config."
        case .malformedJSON:
            return "presets.json has invalid JSON — using last-good config."
        case .missingDefaultKey:
            return "presets.json missing 'default' entry — using last-good config."
        case .fileTooLarge:
            return "presets.json is too large (max 512 KB) — using last-good config."
        case .tooManyOverrides:
            return "Too many app overrides in presets.json (max 100) — using last-good config."
        case .templateTooLong:
            return "A presets.json template is too long (max 16 KB) — using last-good config."
        case .notRegularFile:
            return "presets.json is not a regular file — using last-good config."
        }
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
        let cleanup = CleanupService(client: ollama, presets: presets)
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

        appState.onTransition = { [audioFeedback] old, new in
            audioFeedback.handle(old: old, new: new)
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
        let presetsDir = PresetStore.defaultFileURL.deletingLastPathComponent()
        let watcher = PresetWatcher(directory: presetsDir, fileName: "presets.json") { [weak self] in
            Task { @MainActor in self?.reloadPresetsAndNotifyOnFailure() }
        }
        watcher.start()
        self.presetWatcher = watcher

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
