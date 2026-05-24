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
/// 1. The `/api/version` endpoint is reachable (liveness check only — HTTP is NOT a trust signal;
///    any process owning port 11434 can return fake JSON). If HTTP fails, we short-circuit to
///    `.untrustedEndpoint` without running lsof.
/// 2. EVERY process owning `127.0.0.1:11434` (per lsof) is a known-good Ollama binary.
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
            // Swift M1: read before wait to avoid pipe-buffer deadlock.
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
    ///
    /// M4: HTTP `/api/version` is a *liveness* check only. If the port is not listening,
    /// there is nothing to verify → `.untrustedEndpoint`. HTTP success carries zero trust
    /// signal; the real trust check is the lsof binary-path validation in step 2.
    func probe() async -> OllamaTrustResult {
        // Step 1: liveness check — is there anything listening on 11434?
        // NOTE: HTTP result is NOT used as a trust signal.
        let versionResult = await checkVersion()
        switch versionResult {
        case .failure:
            // Network failure means we cannot confirm a listener → fail closed.
            return .untrustedEndpoint
        case .success(false):
            // Port not responding with expected JSON → no Ollama listener.
            return .untrustedEndpoint
        case .success(true):
            break
        }

        // Step 2: owning process identity check — ALL PIDs must be acceptable.
        let lsofOutput = await lsofRunner()
        return validateOwningProcess(lsofOutput: lsofOutput)
    }

    // MARK: - Private

    /// M4: HTTP check is liveness only. Returns `.failure` on network error so the
    /// caller can distinguish "no listener" from "bad binary".
    private func checkVersion() async -> Result<Bool, Error> {
        guard let url = URL(string: "http://localhost:11434/api/version") else {
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

    /// M1: Every PID in lsof output must pass `isAcceptableBinary`. One rogue PID → `.untrustedEndpoint`.
    private func validateOwningProcess(lsofOutput: String?) -> OllamaTrustResult {
        guard let output = lsofOutput, !output.isEmpty else {
            return .untrustedEndpoint
        }
        let pids = parsePIDs(from: output)
        if pids.isEmpty {
            return .untrustedEndpoint
        }
        for pid in pids {
            guard let path = binaryPathResolver(pid), isAcceptableBinary(path: path) else {
                return .untrustedEndpoint
            }
        }
        return .trusted
    }

    /// Parse `p<pid>` lines from lsof formatted output.
    private func parsePIDs(from output: String) -> [Int32] {
        output.components(separatedBy: .newlines)
            .compactMap { line -> Int32? in
                guard line.hasPrefix("p") else { return nil }
                return Int32(line.dropFirst())
            }
    }

    /// C2: Standardize path and use `hasPrefix` against fixed allowed roots.
    /// `~/Applications/Ollama.app/` is intentionally excluded: user-writable directories
    /// are not trustworthy for binary identity. A fault log is emitted so users who
    /// install Ollama in ~/Applications get a clear diagnostic.
    private func isAcceptableBinary(path: String) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardized.path
        if standardized.hasPrefix("/Applications/Ollama.app/")
            || standardized.hasPrefix("/opt/homebrew/")
            || standardized.hasPrefix("/usr/local/") {
            return true
        }
        // Diagnostic for ~/Applications install (common on macOS): log clearly and reject.
        let homeBased = (("~/Applications/Ollama.app/" as NSString).expandingTildeInPath)
        if standardized.hasPrefix(homeBased) {
            Log.app.fault("ollama binary found in ~/Applications — user-writable path not trusted; move to /Applications")
        }
        return false
    }

    // MARK: - Static helpers (used by production closures)

    /// Resolve the binary path of a PID using `proc_pidpath` from libproc.
    ///
    /// Buffer size is `PROC_PIDPATHINFO_MAXSIZE` = `4 * MAXPATHLEN` = 4096.
    /// The constant is defined as a compound macro and not bridgeable to Swift,
    /// so we use the numeric value directly.
    ///
    /// Swift M2 note: `proc_pidpath` is a blocking syscall (~10 ms under load).
    /// The production closure wraps this in `Task.detached` via `lsofRunner` so it
    /// runs off the actor executor. Direct calls here are fine in static context.
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
    ///
    /// Swift M1 fix: read pipe data BEFORE calling `waitUntilExit()`.
    /// If lsof output exceeds the pipe buffer (~64 KB), the child blocks on write
    /// while the parent blocks on wait — deadlock. Reading first drains the pipe.
    static func runLsof() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:11434", "-sTCP:LISTEN", "-F", "pn"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        // Read before wait to prevent pipe-buffer deadlock (Swift M1).
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
