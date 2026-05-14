#if canImport(Darwin)
import Darwin
#endif
import Foundation

/// Result of the Ollama endpoint trust probe.
enum OllamaTrustResult {
    case trusted
    case untrustedEndpoint
    case probeFailed(Error)
}

/// Startup trust probe for the Ollama endpoint.
///
/// Validates two things:
/// 1. The `/api/version` endpoint returns `{"version": String}`.
/// 2. The process owning `127.0.0.1:11434` is a known-good Ollama binary.
///
/// Designed for testability: `lsofRunner` and `binaryPathResolver` closures are
/// injectable so unit tests can stub both without needing a real Ollama process.
actor OllamaTrustProbe {
    private let session: URLSession
    /// Returns raw lsof stdout, or nil on failure.
    private let lsofRunner: @Sendable () async -> String?
    /// Resolves a binary path for a given PID; returns nil when unknown.
    private let binaryPathResolver: @Sendable (Int32) -> String?

    /// Production initializer.
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 2
        self.session = URLSession(configuration: config)
        self.lsofRunner = {
            await Task.detached { OllamaTrustProbe.runLsof() }.value
        }
        self.binaryPathResolver = { pid in
            OllamaTrustProbe.resolveBinaryPath(pid: pid)
        }
    }

    /// Testability initializer.
    init(
        session: URLSession,
        lsofRunner: @escaping @Sendable () async -> String?,
        binaryPathResolver: @escaping @Sendable (Int32) -> String? = { _ in nil }
    ) {
        self.session = session
        self.lsofRunner = lsofRunner
        self.binaryPathResolver = binaryPathResolver
    }

    /// Run the probe. Returns `.trusted`, `.untrustedEndpoint`, or `.probeFailed`.
    func probe() async -> OllamaTrustResult {
        // Step 1: version endpoint validation.
        let versionResult = await checkVersion()
        switch versionResult {
        case .failure(let error):
            return .probeFailed(error)
        case .success(false):
            return .untrustedEndpoint
        case .success(true):
            break
        }

        // Step 2: owning process identity check.
        let lsofOutput = await lsofRunner()
        return validateOwningProcess(lsofOutput: lsofOutput)
    }

    // MARK: - Private

    private func checkVersion() async -> Result<Bool, Error> {
        guard let url = URL(string: "http://127.0.0.1:11434/api/version") else {
            return .success(false)
        }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return .success(false)
            }
            guard
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                obj["version"] is String
            else {
                return .success(false)
            }
            return .success(true)
        } catch {
            return .failure(error)
        }
    }

    private func validateOwningProcess(lsofOutput: String?) -> OllamaTrustResult {
        guard let output = lsofOutput, !output.isEmpty else {
            return .untrustedEndpoint
        }
        let pids = parsePIDs(from: output)
        if pids.isEmpty {
            return .untrustedEndpoint
        }
        for pid in pids {
            if let path = binaryPathResolver(pid), isAcceptableBinary(path: path) {
                return .trusted
            }
        }
        return .untrustedEndpoint
    }

    /// Parse `p<pid>` lines from lsof formatted output.
    private func parsePIDs(from output: String) -> [Int32] {
        output.components(separatedBy: .newlines)
            .compactMap { line -> Int32? in
                guard line.hasPrefix("p") else { return nil }
                return Int32(line.dropFirst())
            }
    }

    private func isAcceptableBinary(path: String) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.contains("/Applications/Ollama.app/")
            || expanded.hasPrefix("/opt/homebrew/")
            || expanded.hasPrefix("/usr/local/")
    }

    // MARK: - Static helpers (used by production closures)

    /// Resolve the binary path of a PID using `proc_pidpath` from libproc.
    ///
    /// Buffer size is `PROC_PIDPATHINFO_MAXSIZE` = `4 * MAXPATHLEN` = 4096.
    /// The constant is defined as a compound macro and not bridgeable to Swift,
    /// so we use the numeric value directly.
    static func resolveBinaryPath(pid: Int32) -> String? {
        #if canImport(Darwin)
        let bufferSize = 4 * 1024 // PROC_PIDPATHINFO_MAXSIZE = 4 * MAXPATHLEN
        var pathBuffer = [CChar](repeating: 0, count: bufferSize)
        let result = proc_pidpath(pid, &pathBuffer, UInt32(bufferSize))
        guard result > 0 else { return nil }
        return String(cString: pathBuffer)
        #else
        return nil
        #endif
    }

    /// Run `/usr/sbin/lsof` to find the process listening on port 11434.
    static func runLsof() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:11434", "-sTCP:LISTEN", "-F", "pn"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
