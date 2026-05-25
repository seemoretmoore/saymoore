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
    private lazy var historyStore: HistoryStore? = {
        do {
            let dir = try HistoryStore.defaultDirectory()
            return try HistoryStore(directory: dir)
        } catch {
            Log.app.error("HistoryStore init failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }()
    private var presetWatcher: PresetWatcher?
    private var menuBar: MenuBarController?
    /// v1.1 — per-session vocab-suggest dedupe state. Held by AppDelegate so
    /// it survives across multiple dictations within the same session.
    private let vocabSuggester = VocabSuggester()
    private var settingsWindow: SettingsWindow?
    private var micMonitor: MicrophonePermissionMonitor?
    private var bootstrap: ModelBootstrap?
    private var bootstrapWindow: ModelDownloadWindow?
    private var permissionsWindow: PermissionsWizardWindow?
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
        menuBar = MenuBarController(appState: appState, presets: presets, historyStore: historyStore)

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
        if let warn = presets.initialSnippetsWarning {
            Log.presets.error("snippets rejected at launch: \(String(describing: warn), privacy: .public)")
            NotificationCenterAdapter.shared.notify(
                title: "Preset warning",
                body: Self.bannerCopy(for: warn)
            )
        }

        // Bundled-preset upgrade check. Existing v1.0.1 users have no
        // `$schemaVersion` field on disk → treated as 0; bundled is currently
        // 1; they get the upgrade prompt. First-launch users skip this path
        // because materializeBaseline copies the bundled file (version
        // included) to disk before this code runs.
        if case let .upgradeAvailable(disk, bundled) = presets.upgradeStatus() {
            Log.presets.info("preset upgrade available: disk=\(disk, privacy: .public) bundled=\(bundled, privacy: .public)")
            DispatchQueue.main.async { [weak self] in
                self?.promptPresetUpgrade(diskVersion: disk, bundledVersion: bundled)
            }
        }

        #if !DEBUG
        // Belt-and-braces: clear any orphan raw-WAVs left by a prior Debug
        // session on this machine. Release builds never write to this dir
        // (persistRawWAV is compile-time-stripped) so it should stay empty.
        RecordingPaths.purgeAll(in: RecordingPaths.defaultDirectory())
        #endif

        Task {
            await permissionsWizardIfNeeded()
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
                    body: "Couldn't verify Ollama trust — dictation paused. \(error.localizedDescription)"
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
        // After-reload UI sync. Keep this in sync with the static signature —
        // the FSEvents path calls into the instance method which then calls
        // this static, and we want the Settings VM to refresh on either path.
        defer {
            if let d = NSApp.delegate as? AppDelegate {
                d.settingsWindow?.notifyExternalReload()
            }
        }
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
            if let warn = outcome.snippetsWarning {
                Log.presets.error("snippets rejected on reload: \(String(describing: warn), privacy: .public)")
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

    /// Prompt the user when bundled `presets.example.json` is newer than the
    /// on-disk file. Three choices: Merge (keep user overrides + vocabulary,
    /// adopt bundled default template), Overwrite (replace entire file), or
    /// Keep Mine (just bump the on-disk version field so we stop nagging).
    @MainActor
    func promptPresetUpgrade(diskVersion: Int, bundledVersion: Int) {
        let alert = NSAlert()
        alert.messageText = "Updated cleanup prompts available"
        alert.informativeText = """
        SayMoore ships an updated set of cleanup prompts (v\(bundledVersion)). Your on-disk presets are v\(diskVersion).

        • Merge — adopt the new default prompt; keep your per-app overrides and vocabulary intact. (Recommended)
        • Overwrite — replace the entire file with the new bundled presets. Loses any custom overrides or vocabulary.
        • Keep Mine — leave prompts alone; stop reminding me until the next update.
        """
        alert.alertStyle = .informational
        // NSAlert button order: first added = rightmost (default). Order here
        // controls visual order; default is Merge (the recommended path).
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Overwrite")
        alert.addButton(withTitle: "Keep Mine")

        let strategy: PresetUpgradeStrategy
        switch alert.runModal() {
        case .alertFirstButtonReturn:  strategy = .merge
        case .alertSecondButtonReturn: strategy = .overwrite
        case .alertThirdButtonReturn:  strategy = .dismiss
        default: return
        }

        do {
            try presets.applyUpgrade(strategy)
            Log.presets.info("preset upgrade applied: strategy=\(String(describing: strategy), privacy: .public)")
            // Hot-reload immediately so the new template is live without
            // waiting for FSEvents (the watcher will also fire, but it
            // dedupes on identical content).
            _ = Self.reloadPresetsAndNotifyOnFailure(presets: presets)
            let bodyByStrategy: String
            switch strategy {
            case .merge:     bodyByStrategy = "Default prompt updated. Your overrides and vocabulary were preserved."
            case .overwrite: bodyByStrategy = "Presets replaced with bundled defaults."
            case .dismiss:   bodyByStrategy = "Marked v\(bundledVersion). You can edit presets anytime from the menu bar."
            }
            NotificationCenterAdapter.shared.notify(title: "SayMoore", body: bodyByStrategy)
        } catch {
            Log.presets.error("preset upgrade failed: \(String(describing: error), privacy: .public)")
            NotificationCenterAdapter.shared.notify(
                title: "Preset upgrade failed",
                body: "Could not write presets.json — \(error.localizedDescription)"
            )
        }
    }

    /// v1.1 Settings window opener (called by MenuBarController). Creates
    /// the window lazily; subsequent calls re-foreground the same instance
    /// so settings state stays consistent across menu invocations.
    @MainActor
    func showSettingsWindow() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindow(
                presets: presets,
                onOpenPresetsFile: { [weak self] in
                    guard let self else { return }
                    self.presets.ensureMaterialized()
                    NSWorkspace.shared.activateFileViewerSelecting([self.presets.fileURL])
                },
                onReloadPresets: { [weak self] in
                    guard let self else { return }
                    _ = Self.reloadPresetsAndNotifyOnFailure(presets: self.presets)
                },
                onCheckForPresetUpdates: { [weak self] in
                    guard let self else { return }
                    switch self.presets.upgradeStatus() {
                    case .upToDate:
                        let alert = NSAlert()
                        alert.messageText = "Presets are up to date"
                        alert.informativeText = "On-disk presets match the bundled baseline (v\(PresetStore.bundledSchemaVersion))."
                        alert.runModal()
                    case .upgradeAvailable(let d, let b):
                        self.promptPresetUpgrade(diskVersion: d, bundledVersion: b)
                    }
                }
            )
        }
        settingsWindow?.show()
    }

    /// v1.1 vocab auto-suggest. Called by PipelineCoordinator after every
    /// successful paste. Surfaces at most one suggestion per session per
    /// term — the user sees "Add 'GraphQL' to vocabulary?" once, and a
    /// repeat dictation with the same proper noun stays quiet.
    @MainActor
    private func considerVocabSuggestion(for cleanedText: String) {
        guard let suggested = vocabSuggester.consider(
            cleanedText: cleanedText,
            existingVocab: presets.vocabulary()
        ) else { return }
        Log.presets.info("vocab-suggest → \(suggested, privacy: .public)")
        NotificationCenterAdapter.shared.notify(
            title: "Add to vocabulary?",
            body: "\"\(suggested)\" looks like a proper noun. Edit presets.json under \"vocabulary\" to capture it on future dictations."
        )
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
        case .tooManySnippets:
            return "Too many snippets in presets.json (max 20) — snippets disabled."
        case .snippetNameInvalid:
            return "A snippet name in presets.json contains invalid characters (only letters, digits, _, -) — snippets disabled."
        case .snippetEntryTooLong:
            return "A snippet entry in presets.json is too long (max 32 bytes for name, 512 bytes for value) — snippets disabled."
        case .snippetsTooLarge:
            return "Snippets in presets.json are too large overall (max 8 KB) — snippets disabled."
        case .snippetsMalformed:
            return "Snippets in presets.json are malformed (expected an object of {name: text} pairs) — snippets disabled."
        }
    }

    private func permissionsWizardIfNeeded() async {
        let checker = LivePermissionChecker()
        guard !(checker.microphoneStatus() == .granted &&
                checker.accessibilityStatus() == .granted &&
                checker.inputMonitoringStatus() == .granted) else { return }
        let win = PermissionsWizardWindow(checker: checker)
        permissionsWindow = win
        await win.present()
        win.close()
        permissionsWindow = nil
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
        let commandService = CommandService(client: ollama)

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
            command: commandService,
            recordingsDir: Self.recordingsDirIfPossible(),
            vadService: vadService,
            historyStore: historyStore,
            streamingModeProvider: { @MainActor in
                let raw = UserDefaults.standard.string(forKey: StreamingMode.userDefaultsKey)
                return raw.flatMap(StreamingMode.init(rawValue:)) ?? .default
            },
            hudPartialSink: { [weak self] committed, active in
                self?.hud.updatePartialText(committed: committed, active: active)
            },
            onFallback: { error in NotificationCoordinator.shared.notify(error) }
        )
        // C1: stamp blocked flag immediately so probe results that landed before
        // coordinator was created are not silently lost.
        coord.blocked = ollamaEndpointBlocked
        coord.onPasteSucceeded = { [weak self] cleaned in
            self?.considerVocabSuggestion(for: cleaned)
        }
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
                if case .ollamaUnreachable = e {
                    let supervisor = await MainActor.run { OllamaSupervisor() }
                    await supervisor.coldSpawn()
                    try? await Task.sleep(for: .seconds(3))
                    if let retryTags = try? await ollama.tags() {
                        Log.cleanup.info("ollama up after cold-spawn, models=\(retryTags.joined(separator: ","), privacy: .public)")
                        await MainActor.run { NotificationCoordinator.shared.clearBadge(for: .ollamaUnreachable) }
                        if !retryTags.contains(where: { $0.hasPrefix("qwen2.5:7b-instruct") }) {
                            await MainActor.run { NotificationCoordinator.shared.notify(.ollamaModelNotPulled) }
                        }
                        return
                    }
                }
                await MainActor.run { NotificationCoordinator.shared.notify(e) }
            } catch {
                Log.cleanup.error("ollama probe error: \(String(describing: error), privacy: .public)")
            }
        }

        appState.onTransition = { [audioFeedback, hud, cursorIndicator, weak self] old, new in
            audioFeedback.handle(old: old, new: new)
            switch (old, new) {
            case (.idle, .recording):
                hud.show()
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
        recorder.onLevelUpdate = { [hud] level in
            Task { @MainActor in hud.updateLevel(level) }
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
