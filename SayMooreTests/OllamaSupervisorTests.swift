import XCTest
@testable import SayMoore

@MainActor
final class OllamaSupervisorTests: XCTestCase {
    func test_spawnInvokesLauncher_whenBinaryExists() async {
        var launched: [URL] = []
        let sup = OllamaSupervisor(
            binaryLocator: { URL(fileURLWithPath: "/usr/local/bin/ollama") },
            launcher: { url in launched.append(url) }
        )
        await sup.coldSpawn()
        XCTAssertEqual(launched.first?.path, "/usr/local/bin/ollama")
    }

    func test_spawnIsNoOp_whenNoBinary() async {
        var launched: [URL] = []
        let sup = OllamaSupervisor(
            binaryLocator: { nil },
            launcher: { url in launched.append(url) }
        )
        await sup.coldSpawn()
        XCTAssertTrue(launched.isEmpty)
    }
}
