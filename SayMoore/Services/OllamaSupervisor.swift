import Foundation

@MainActor
final class OllamaSupervisor {
    private let binaryLocator: () -> URL?
    private let launcher: (URL) -> Void

    nonisolated static func defaultBinaryLocator() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/ollama",
            "/usr/local/bin/ollama",
            "/Applications/Ollama.app/Contents/Resources/ollama"
        ]
        return candidates.map(URL.init(fileURLWithPath:)).first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    nonisolated static func defaultLauncher(_ url: URL) {
        let proc = Process()
        proc.executableURL = url
        proc.arguments = ["serve"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            Log.cleanup.error("OllamaSupervisor launch failed: \(String(describing: error), privacy: .public)")
        }
    }

    init(
        binaryLocator: @escaping () -> URL? = OllamaSupervisor.defaultBinaryLocator,
        launcher: @escaping (URL) -> Void = OllamaSupervisor.defaultLauncher
    ) {
        self.binaryLocator = binaryLocator
        self.launcher = launcher
    }

    func coldSpawn() async {
        guard let url = binaryLocator() else {
            Log.cleanup.info("OllamaSupervisor: no ollama binary found")
            return
        }
        Log.cleanup.info("OllamaSupervisor: launching \(url.path, privacy: .public) serve")
        launcher(url)
    }
}
