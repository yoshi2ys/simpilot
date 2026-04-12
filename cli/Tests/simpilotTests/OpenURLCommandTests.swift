import XCTest
@testable import simpilot

/// Tests `OpenURLCommand.resolveAgent` — the pure port→AgentRecord lookup
/// extracted in Wave 3b fix #1. Verifies that openurl respects `context.port`
/// the same way every other command does (no `agents.first` fallback).
final class OpenURLCommandTests: XCTestCase {

    // MARK: - resolveAgent (port → AgentRecord)

    func testResolveAgentMatchesByPort() throws {
        let agents = [rec(port: 8222, udid: "A"), rec(port: 8223, udid: "B")]
        let match = try OpenURLCommand.resolveAgent(port: 8223, agents: agents)
        XCTAssertEqual(match.port, 8223)
        XCTAssertEqual(match.udid, "B")
    }

    func testResolveAgentPicksMatchingPortNotFirst() throws {
        let agents = [rec(port: 8223, udid: "B"), rec(port: 8222, udid: "A")]
        let match = try OpenURLCommand.resolveAgent(port: 8222, agents: agents)
        XCTAssertEqual(match.udid, "A")
    }

    func testResolveAgentNoMatchThrows() {
        let agents = [rec(port: 8222, udid: "A")]
        XCTAssertThrowsError(try OpenURLCommand.resolveAgent(port: 9999, agents: agents)) { error in
            assertCommandFailed(error, contains: "No agent found on port 9999")
        }
    }

    func testResolveAgentEmptyRegistryThrows() {
        XCTAssertThrowsError(try OpenURLCommand.resolveAgent(port: 8222, agents: [])) { error in
            assertCommandFailed(error, contains: "No agent found on port 8222")
        }
    }

    func testResolveAgentReturnsPhysicalRecord() throws {
        let agents = [rec(port: 8222, udid: "PHYS-1", isPhysical: true)]
        let match = try OpenURLCommand.resolveAgent(port: 8222, agents: agents)
        XCTAssertTrue(match.isPhysical)
    }

    // MARK: - Helpers

    private func rec(port: Int, udid: String, isPhysical: Bool = false) -> AgentRecord {
        AgentRecord(
            port: port,
            pid: 0,
            udid: udid,
            device: "Test",
            isClone: false,
            startedAt: Date(),
            host: "localhost",
            isPhysical: isPhysical
        )
    }

    private func assertCommandFailed(
        _ error: Error,
        contains needle: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case CLIError.commandFailed(let msg) = error else {
            XCTFail("Expected CLIError.commandFailed, got \(error)", file: file, line: line)
            return
        }
        XCTAssertTrue(
            msg.contains(needle),
            "Expected error message to contain '\(needle)', got: \(msg)",
            file: file,
            line: line
        )
    }
}
