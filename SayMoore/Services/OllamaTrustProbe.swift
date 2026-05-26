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
    /// Returns file metadata for cache invalidation; nil means the binary does not exist.
    private let binaryMetadataProvider: @Sendable (String) -> BinaryFileMetadata?
    /// Runs codesign verification/details commands.
    private let codesignRunner: @Sendable (CodesignInvocation, String) async -> CodesignProcessResult
    private var binaryVerificationCache: [BinaryVerificationCacheKey: Result<Void, Error>] = [:]

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
        self.binaryMetadataProvider = { path in
            OllamaTrustProbe.binaryMetadata(path: path)
        }
        self.codesignRunner = { invocation, path in
            await Task.detached { OllamaTrustProbe.runCodesign(invocation, path: path) }.value
        }
    }

    /// Testability initializer.
    init(
        session: URLSession,
        lsofRunner: @escaping @Sendable () async -> String?,
        binaryPathResolver: @escaping @Sendable (Int32) -> String? = { _ in nil },
        binaryMetadataProvider: @escaping @Sendable (String) -> BinaryFileMetadata? = { path in
            OllamaTrustProbe.binaryMetadata(path: path)
        },
        codesignRunner: @escaping @Sendable (CodesignInvocation, String) async -> CodesignProcessResult = { invocation, path in
            await Task.detached { OllamaTrustProbe.runCodesign(invocation, path: path) }.value
        }
    ) {
        self.session = session
        self.lsofRunner = lsofRunner
        self.binaryPathResolver = binaryPathResolver
        self.binaryMetadataProvider = binaryMetadataProvider
        self.codesignRunner = codesignRunner
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
        return await validateOwningProcess(lsofOutput: lsofOutput)
    }

    // MARK: - Private

    /// Team IDs we accept for the Ollama binary. Ollama's signing identity
    /// changed when the project restructured under "Infra Technologies, Inc"
    /// — both certificates are legitimate, Apple-issued, and notarized:
    ///   - `FX44YY62GV` — original "Ollama, Inc." Developer ID
    ///   - `3MU9H2V9Y9` — current "Infra Technologies, Inc" Developer ID
    /// A new entry here is a security decision: never add a Team ID without
    /// independently verifying the certificate chain on a fresh download
    /// from ollama.com.
    static let ollamaTeamIdentifiers: Set<String> = ["FX44YY62GV", "3MU9H2V9Y9"]

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
    private func validateOwningProcess(lsofOutput: String?) async -> OllamaTrustResult {
        guard let output = lsofOutput, !output.isEmpty else {
            return .untrustedEndpoint
        }
        let pids = parsePIDs(from: output)
        if pids.isEmpty {
            return .untrustedEndpoint
        }
        for pid in pids {
            guard let path = binaryPathResolver(pid) else {
                return .untrustedEndpoint
            }
            let verification = await verifyAcceptableBinary(path: path)
            switch verification {
            case .success:
                break
            case .failure(let error as OllamaTrustProbeError):
                if error.isPathRejection {
                    return .untrustedEndpoint
                }
                return .probeFailed(error)
            case .failure(let error):
                return .probeFailed(error)
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

    /// C2: Standardize path and require fixed allowed roots before expensive signature checks.
    /// `~/Applications/Ollama.app/` is intentionally excluded: user-writable directories
    /// are not trustworthy for binary identity. A fault log is emitted so users who
    /// install Ollama in ~/Applications get a clear diagnostic.
    private func verifyAcceptableBinary(path: String) async -> Result<Void, Error> {
        let standardized = URL(fileURLWithPath: path).standardized.path
        guard isExpectedOllamaPath(standardized) else {
            logUserScopedApplicationsInstallIfNeeded(standardized)
            return .failure(OllamaTrustProbeError.unexpectedPath(standardized))
        }

        guard let metadata = binaryMetadataProvider(standardized) else {
            return .failure(OllamaTrustProbeError.binaryNotFound(path: standardized))
        }

        let cacheKey = BinaryVerificationCacheKey(path: standardized, metadata: metadata)
        if let cached = binaryVerificationCache[cacheKey] {
            return cached
        }

        let result = await verifyCodesign(path: standardized)
        binaryVerificationCache[cacheKey] = result
        return result
    }

    private func isExpectedOllamaPath(_ path: String) -> Bool {
        path.hasPrefix("/Applications/Ollama.app/")
            || path == "/opt/homebrew/bin/ollama"
            || path == "/usr/local/bin/ollama"
    }

    private func logUserScopedApplicationsInstallIfNeeded(_ standardized: String) {
        let homeBased = (("~/Applications/Ollama.app/" as NSString).expandingTildeInPath)
        if standardized.hasPrefix(homeBased) {
            Log.app.fault("ollama binary found in ~/Applications — user-writable path not trusted; move to /Applications")
        }
    }

    private func verifyCodesign(path: String) async -> Result<Void, Error> {
        let verify = await codesignRunner(.verify, path)
        guard verify.exitCode == 0 else {
            return .failure(OllamaTrustProbeError.codesignVerifyFailed(path: path, output: verify.output))
        }

        let describe = await codesignRunner(.describe, path)
        guard describe.exitCode == 0 else {
            return .failure(OllamaTrustProbeError.codesignDescribeFailed(path: path, output: describe.output))
        }

        let details = CodesignDetails(output: describe.output)
        guard let teamIdentifier = details.teamIdentifier else {
            return .failure(OllamaTrustProbeError.missingTeamIdentifier(path: path, authorities: details.authorities))
        }
        guard Self.ollamaTeamIdentifiers.contains(teamIdentifier) else {
            return .failure(OllamaTrustProbeError.unexpectedTeamIdentifier(
                path: path,
                expected: Self.ollamaTeamIdentifiers.sorted().joined(separator: ", "),
                actual: teamIdentifier,
                authorities: details.authorities
            ))
        }
        guard details.hasDeveloperIDAuthority else {
            return .failure(OllamaTrustProbeError.missingDeveloperIDAuthority(path: path, authorities: details.authorities))
        }
        return .success(())
    }

    // MARK: - Static helpers (used by production closures)

    enum CodesignInvocation: Hashable, Sendable {
        case verify
        case describe
    }

    struct CodesignProcessResult: Sendable {
        let exitCode: Int32
        let output: String
    }

    struct BinaryFileMetadata: Hashable, Sendable {
        let modificationTime: TimeInterval
        let size: UInt64
    }

    private struct BinaryVerificationCacheKey: Hashable {
        let path: String
        let modificationTime: TimeInterval
        let size: UInt64

        init(path: String, metadata: BinaryFileMetadata) {
            self.path = path
            self.modificationTime = metadata.modificationTime
            self.size = metadata.size
        }
    }

    private struct CodesignDetails {
        let teamIdentifier: String?
        let authorities: [String]

        init(output: String) {
            var parsedTeamIdentifier: String?
            var parsedAuthorities: [String] = []
            for line in output.components(separatedBy: .newlines) {
                if line.hasPrefix("TeamIdentifier=") {
                    parsedTeamIdentifier = String(line.dropFirst("TeamIdentifier=".count))
                } else if line.hasPrefix("Authority=") {
                    parsedAuthorities.append(String(line.dropFirst("Authority=".count)))
                }
            }
            self.teamIdentifier = parsedTeamIdentifier
            self.authorities = parsedAuthorities
        }

        var hasDeveloperIDAuthority: Bool {
            authorities.contains { $0.hasPrefix("Developer ID Application:") }
                && authorities.contains("Developer ID Certification Authority")
                && authorities.contains("Apple Root CA")
        }
    }

    enum OllamaTrustProbeError: LocalizedError, CustomStringConvertible {
        case unexpectedPath(String)
        case binaryNotFound(path: String)
        case codesignVerifyFailed(path: String, output: String)
        case codesignDescribeFailed(path: String, output: String)
        case missingTeamIdentifier(path: String, authorities: [String])
        case unexpectedTeamIdentifier(path: String, expected: String, actual: String, authorities: [String])
        case missingDeveloperIDAuthority(path: String, authorities: [String])

        var isPathRejection: Bool {
            if case .unexpectedPath = self { return true }
            return false
        }

        var errorDescription: String? {
            switch self {
            case .unexpectedPath(let path):
                return "Ollama binary is not in a trusted install location: \(path)"
            case .binaryNotFound(let path):
                return "Ollama binary not found at expected path: \(path)"
            case .codesignVerifyFailed(let path, let output):
                return "codesign --verify failed for Ollama binary at \(path): \(trimmed(output))"
            case .codesignDescribeFailed(let path, let output):
                return "codesign -dvv failed for Ollama binary at \(path): \(trimmed(output))"
            case .missingTeamIdentifier(let path, let authorities):
                return "Ollama binary at \(path) has no TeamIdentifier. Authorities: \(authorities.joined(separator: " | "))"
            case .unexpectedTeamIdentifier(let path, let expected, let actual, let authorities):
                return "Ollama binary at \(path) has unexpected TeamIdentifier \(actual); expected \(expected). Authorities: \(authorities.joined(separator: " | "))"
            case .missingDeveloperIDAuthority(let path, let authorities):
                return "Ollama binary at \(path) is missing the expected Developer ID authority chain. Authorities: \(authorities.joined(separator: " | "))"
            }
        }

        var description: String {
            errorDescription ?? "Ollama trust probe failed"
        }

        private func trimmed(_ output: String) -> String {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "<no output>" : trimmed
        }
    }

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

    static func binaryMetadata(path: String) -> BinaryFileMetadata? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            guard let modificationDate = attributes[.modificationDate] as? Date else {
                return nil
            }
            let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            return BinaryFileMetadata(modificationTime: modificationDate.timeIntervalSince1970, size: fileSize)
        } catch {
            return nil
        }
    }

    static func runCodesign(_ invocation: CodesignInvocation, path: String) -> CodesignProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        switch invocation {
        case .verify:
            process.arguments = ["--verify", "--deep", "--strict", path]
        case .describe:
            process.arguments = ["-dvv", path]
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return CodesignProcessResult(exitCode: 127, output: String(describing: error))
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        return CodesignProcessResult(exitCode: process.terminationStatus, output: output)
    }
}
