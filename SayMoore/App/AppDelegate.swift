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
    private var micMonitor: MicrophonePermissionMonitor?
    private var bootstrap: ModelBootstrap?
    private var bootstrapWindow: ModelDownloadWindow?
    private let audioFeedback = AudioFeedbackService()
    private let hud = RecordingHUDController()
    private let cursorIndicator = CursorIndicatorController()
    private var lastBundleID: String?
    private var lastCursorPoint: NSPoint = .zero
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

        // Surface any vocabulary warning captured during PresetStore.init.
        // PresetStore has already primed its dedupe state with this warning,
        // so a subsequent reload of the same broken file won't re-post.
        if let warn = presets.initialVocabularyWarning {
            Log.presets.error("vocabulary rejected at launch: \(String(describing: warn), privacy: .public)")
            NotificationCenterAdapter.shared.notify(
                title: "Preset warning",
                body: Self.bannerCopy(for: warn)
            )
        }

        #if !DEBUG
        // Belt-and-braces: clear any orphan raw-WAVs left by a prior Debug
        // session on this machine. Release builds never write to this dir
        // (persistRawWAV is compile-time-stripped) so it should stay empty.
        RecordingPaths.purgeAll(in: RecordingPaths.defaultDirectory())
        #endif

        Task {
            await bootstrapModelThenStart()
        }

        // Trust probe — runs concurrently with bootstrap.
        // C1: ollamaEndpointBlocked is the bridge flag: written here so startPipeline()
        // can stamp the coordinator immediately on creation even if the probe already finished.
        // M2: .probeFailed is fail-closed — dictation paused until trust can be confirmed.
        Task {
            let result = await OllamaTrustProbe().probe()
            switch result {
            case .trusted:
                break
            case .untrustedEndpoint:
                ollamaEndpointBlocked = true
                coordinator?.blocked = true
                NotificationCoordinator.shared.notify(.ollamaEndpointUntrusted)
                Log.app.error("ollama endpoint trust probe: untrusted — dictation blocked")
            case .probeFailed(let error):
                // M2: fail-closed — treat verification failure as blocking.
                ollamaEndpointBlocked = true
                coordinator?.blocked = true
                NotificationCenterAdapter.shared.notify(
                    title: "SayMoore",
                    body: "Couldn't verify Ollama trust — dictation paused. Check Console for details."
                )
                Log.app.fault("ollama endpoint trust probe failed — dictation blocked: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch appState.state {
        case .idle, .error:
            return .terminateNow
        case .recording:
            let alert = NSAlert()
            alert.messageText = "Discard current dictation and quit?"
            alert.informativeText = "Recording will be discarded."
            alert.addButton(withTitle: "Discard & Quit")
            alert.addButton(withTitle: "Cancel")
            let resp = alert.runModal()
            if resp == .alertFirstButtonReturn {
                coordinator?.cancel()
                return .terminateNow
            }
            return .terminateCancel
        case .transcribing, .cleaning, .pasting:
            Task { @MainActor in
                let deadline = Date().addingTimeInterval(5)
                while Date() < deadline && self.appState.state != .idle {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey.stop()
        presetWatcher?.stop()
        micMonitor?.stop()
        Log.app.info("SayMoore terminating")
    }

    /// Shared by AppDelegate's FSEvent path and `MenuBarController`'s menu-action
    /// path. Returns `true` on successful reload (whether or not a vocabulary
    /// warning was surfaced); `false` only on hard reload errors (which post
    /// the existing error banner). Vocabulary-warning dedupe lives on
    /// `PresetStore`, so repeat saves of the same broken file stay quiet.
    @MainActor
    @discardableResult
    static func reloadPresetsAndNotifyOnFailure(presets: PresetStore) -> Bool {
        do {
            let outcome = try presets.reload()
            Log.presets.info("presets.json reloaded")
            if let warn = outcome.vocabularyWarning {
                Log.presets.error("vocabulary rejected on reload: \(String(describing: warn), privacy: .public)")
                NotificationCenterAdapter.shared.notify(
                    title: "Preset warning",
                    body: bannerCopy(for: warn)
                )
            }
            return true
        } catch {
            Log.presets.error("presets reload failed: \(String(describing: error), privacy: .public)")
            NotificationCenterAdapter.shared.notify(
                title: "Preset error",
                body: bannerCopy(for: error)
            )
            return false
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
        case .tooManyVocabEntries:
            return "Too many vocabulary entries in presets.json (max 50) — vocabulary disabled."
        case .vocabEntryTooLong:
            return "A vocabulary entry in presets.json is too long (max 64 bytes) — vocabulary disabled."
        case .vocabularyTooLarge:
            return "Vocabulary in presets.json is too large overall (max 512 B) — vocabulary disabled."
        case .vocabularyMalformed:
            return "Vocabulary in presets.json is malformed (expected an array of {phonetic, canonical} entries) — vocabulary disabled."
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

        // Slice 5: Silero VAD. If the model file fails to load, log and continue
        // without VAD — the 90s length-cap timer is still armed by PipelineCoordinator.
        let vadService: VADService?
        if let sileroPath = Bundle.main.path(forResource: "silero_vad", ofType: "onnx") {
            do {
                let backend = try SileroVADBackend(modelPath: sileroPath)
                vadService = VADService(backend: backend)
                Log.vad.info("Silero VAD loaded from \(sileroPath, privacy: .public)")
            } catch {
                Log.vad.error("Silero VAD init failed, continuing without VAD: \(String(describing: error), privacy: .public)")
                vadService = nil
            }
        } else {
            Log.vad.error("silero_vad.onnx not found in bundle — run scripts/setup-silero.sh")
            vadService = nil
        }

        let coord = PipelineCoordinator(
            appState: appState,
            recorder: recorder,
            transcription: svc,
            paste: paste,
            presets: presets,
            cleanup: cleanup,
            recordingsDir: Self.recordingsDirIfPossible(),
            vadService: vadService,
            onFallback: { error in NotificationCoordinator.shared.notify(error) }
        )
        // C1: stamp blocked flag immediately so probe results that landed before
        // coordinator was created are not silently lost.
        coord.blocked = ollamaEndpointBlocked
        self.coordinator = coord

        // Fire-and-forget Ollama health probe.
        Task.detached {
            do {
                let tags = try await ollama.tags()
                Log.cleanup.info("ollama up, models=\(tags.joined(separator: ","), privacy: .public)")
                if !tags.contains(where: { $0.hasPrefix("qwen2.5:7b-instruct") }) {
                    await MainActor.run { NotificationCoordinator.shared.notify(.ollamaModelNotPulled) }
                }
            } catch let e as SayMooreError {
                await MainActor.run { NotificationCoordinator.shared.notify(e) }
            } catch {
                Log.cleanup.error("ollama probe error: \(String(describing: error), privacy: .public)")
            }
        }

        appState.onTransition = { [audioFeedback, hud, cursorIndicator, weak self] old, new in
            audioFeedback.handle(old: old, new: new)
            switch (old, new) {
            case (.idle, .recording):
                let label = PresetDisplayName.resolve(bundleID: self?.lastBundleID)
                hud.show(preset: label)
                cursorIndicator.show(at: self?.lastCursorPoint ?? .zero)
            case (.recording, _):
                hud.hide()
                cursorIndicator.hide()
            default:
                break
            }
        }
        coordinator?.onBusyHotkey = { [audioFeedback] in
            audioFeedback.busy()
        }
        recorder.onDeviceChange = { [weak coordinator = self.coordinator] in
            coordinator?.handleAudioDeviceChange()
        }
        coordinator?.onLengthCapPhase = { [weak menuBar] phase in
            menuBar?.setPhase(phase)
        }

        hotkey.isRecording = { [weak self] in
            self?.appState.state == .recording
        }
        hotkey.onToggle = { [weak self] bundleID, cursorPoint in
            self?.lastBundleID = bundleID
            self?.lastCursorPoint = cursorPoint
            self?.coordinator?.toggle(bundleID: bundleID)
        }
        hotkey.onCancel = { [weak self] in
            self?.coordinator?.cancel()
        }
        let presetsDir = PresetStore.defaultFileURL.deletingLastPathComponent()
        let watcher = PresetWatcher(directory: presetsDir, fileName: "presets.json") { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                _ = Self.reloadPresetsAndNotifyOnFailure(presets: self.presets)
            }
        }
        watcher.start()
        self.presetWatcher = watcher

        hotkey.start()
        NotificationCoordinator.shared.onBadgeChange = { [weak menuBar] badge in
            menuBar?.setBadge(badge)
        }
        let mon = MicrophonePermissionMonitor(onRevoked: { [weak self] in
            NotificationCoordinator.shared.notify(.permissionRevokedMidSession(.microphone))
            self?.coordinator?.cancel()
        })
        mon.start()
        self.micMonitor = mon
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
