import XCTest

/// Pure tests for the agent's startup configuration. The security invariant
/// under test: no configuration can produce a network-reachable listener
/// without a token.
final class AgentConfigTests: XCTestCase {

    // MARK: - Defaults

    func testEmptyEnvironmentDefaultsToLoopbackWithoutToken() throws {
        let config = try AgentConfig.resolve(env: [:])
        XCTAssertEqual(config.port, AgentConfig.defaultPort)
        XCTAssertEqual(config.bind, .loopback)
        XCTAssertNil(config.token)
    }

    func testBlankValuesFallBackToDefaults() throws {
        let config = try AgentConfig.resolve(env: [
            "SIMPILOT_PORT": "   ",
            "SIMPILOT_BIND": "",
            "SIMPILOT_TOKEN": "  \n "
        ])
        XCTAssertEqual(config.port, AgentConfig.defaultPort)
        XCTAssertEqual(config.bind, .loopback)
        XCTAssertNil(config.token, "whitespace-only token must not read as configured")
    }

    // MARK: - Port

    func testPortIsReadFromEnvironment() throws {
        XCTAssertEqual(try AgentConfig.resolve(env: ["SIMPILOT_PORT": "8299"]).port, 8299)
        XCTAssertEqual(try AgentConfig.resolve(env: ["SIMPILOT_PORT": " 8300 "]).port, 8300)
    }

    func testInvalidPortThrows() {
        for raw in ["0", "-1", "65536", "abc", "80.5"] {
            XCTAssertThrowsError(try AgentConfig.resolve(env: ["SIMPILOT_PORT": raw]), "port '\(raw)'") { error in
                guard case AgentConfig.ConfigError.invalidPort = error else {
                    return XCTFail("expected invalidPort for '\(raw)', got \(error)")
                }
            }
        }
    }

    // MARK: - Bind mode

    func testUnknownBindModeThrows() {
        XCTAssertThrowsError(try AgentConfig.resolve(env: ["SIMPILOT_BIND": "lan"])) { error in
            guard case AgentConfig.ConfigError.invalidBind = error else {
                return XCTFail("expected invalidBind, got \(error)")
            }
        }
    }

    func testExplicitLoopbackNeedsNoToken() throws {
        let config = try AgentConfig.resolve(env: ["SIMPILOT_BIND": "loopback"])
        XCTAssertEqual(config.bind, .loopback)
        XCTAssertNil(config.token)
    }

    // MARK: - The security invariant

    func testBindAllWithoutTokenIsRefused() {
        XCTAssertThrowsError(try AgentConfig.resolve(env: ["SIMPILOT_BIND": "all"])) { error in
            guard case AgentConfig.ConfigError.unauthenticatedPublicBind = error else {
                return XCTFail("expected unauthenticatedPublicBind, got \(error)")
            }
        }
    }

    func testBindAllWithBlankTokenIsRefused() {
        XCTAssertThrowsError(
            try AgentConfig.resolve(env: ["SIMPILOT_BIND": "all", "SIMPILOT_TOKEN": "   "])
        ) { error in
            guard case AgentConfig.ConfigError.unauthenticatedPublicBind = error else {
                return XCTFail("expected unauthenticatedPublicBind, got \(error)")
            }
        }
    }

    func testBindAllWithTokenIsAccepted() throws {
        let config = try AgentConfig.resolve(env: [
            "SIMPILOT_BIND": "all",
            "SIMPILOT_TOKEN": "deadbeef",
            "SIMPILOT_PORT": "8222"
        ])
        XCTAssertEqual(config.bind, .all)
        XCTAssertEqual(config.token, "deadbeef")
    }

    func testLoopbackWithTokenStillRequiresIt() throws {
        let config = try AgentConfig.resolve(env: ["SIMPILOT_TOKEN": "abc123"])
        XCTAssertEqual(config.bind, .loopback)
        XCTAssertEqual(config.token, "abc123", "a loopback agent given a token must still enforce it")
    }

    // MARK: - TokenAuth

    func testTokenComparison() {
        XCTAssertTrue(TokenAuth.matches(expected: "abc123", provided: "abc123"))
        XCTAssertFalse(TokenAuth.matches(expected: "abc123", provided: "abc124"))
        XCTAssertFalse(TokenAuth.matches(expected: "abc123", provided: "abc12"), "length mismatch")
        XCTAssertFalse(TokenAuth.matches(expected: "abc123", provided: "abc1234"), "length mismatch")
        XCTAssertFalse(TokenAuth.matches(expected: "abc123", provided: nil), "absent header")
        XCTAssertFalse(TokenAuth.matches(expected: "abc123", provided: ""), "empty header")
    }

    func testTokenComparisonIsByteExact() {
        // Multi-byte UTF-8: same character count, different bytes.
        XCTAssertFalse(TokenAuth.matches(expected: "é", provided: "e"))
        XCTAssertTrue(TokenAuth.matches(expected: "é", provided: "é"))
    }

    func testHeaderNameMatchesTheClientContract() {
        XCTAssertEqual(TokenAuth.headerName, "X-Simpilot-Token")
    }
}
