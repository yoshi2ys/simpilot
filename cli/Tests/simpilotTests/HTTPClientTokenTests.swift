import XCTest
@testable import simpilot

/// The CLI must present the agent's shared token on every request, and must
/// build URLs the agent can actually be reached at (IPv6 bracketing).
final class HTTPClientTokenTests: XCTestCase {

    func testTokenIsSentOnEveryRequest() throws {
        let client = HTTPClient(host: "127.0.0.1", port: 8222, token: "cafebabe")
        let request = try client.makeRequest("/health", timeout: nil)
        XCTAssertEqual(request.value(forHTTPHeaderField: HTTPClient.tokenHeader), "cafebabe")
    }

    func testNoHeaderWhenAgentHasNoToken() throws {
        let client = HTTPClient(host: "127.0.0.1", port: 8222, token: nil)
        let request = try client.makeRequest("/health", timeout: nil)
        XCTAssertNil(request.value(forHTTPHeaderField: HTTPClient.tokenHeader))
    }

    func testHeaderNameMatchesTheAgentContract() {
        // The agent compares against `TokenAuth.headerName`; if these drift,
        // every request 401s.
        XCTAssertEqual(HTTPClient.tokenHeader, "X-Simpilot-Token")
    }

    /// The agent lives in a separate build target, so the `TEST_RUNNER_*`
    /// contract cannot be a shared constant. These literals are the contract:
    /// the agent's `AgentConfig.resolve` reads `SIMPILOT_{PORT,BIND,TOKEN}` and
    /// accepts exactly `"loopback"` / `"all"`. Drift here means the agent
    /// silently falls back to port 8222 with no token, and `start` times out.
    func testBindModeMatchesTheAgentsAcceptedValues() {
        XCTAssertEqual(StartCommand.bindMode(isPhysical: false), "loopback")
        XCTAssertEqual(
            StartCommand.bindMode(isPhysical: true), "all",
            "a physical device is reached over USB/Wi-Fi, so it cannot bind loopback"
        )
    }

    /// `HTTPClient` deliberately does not inspect HTTP status (non-2xx envelopes
    /// are meaningful elsewhere), so `waitForHealth` must read the envelope. A
    /// bare "we got bytes" check accepts a `401` from a *different* agent
    /// already holding the port, and `start` would then register the new token
    /// against the old agent.
    func testHealthEnvelopeRequiresSuccessTrue() {
        XCTAssertTrue(StartCommand.isHealthyEnvelope(Data(#"{"success":true,"data":{"status":"ready"}}"#.utf8)))
        XCTAssertFalse(
            StartCommand.isHealthyEnvelope(Data(#"{"success":false,"error":{"code":"unauthorized"}}"#.utf8)),
            "a 401 from a foreign agent must not read as healthy"
        )
        XCTAssertFalse(StartCommand.isHealthyEnvelope(Data("<html>502</html>".utf8)))
        XCTAssertFalse(StartCommand.isHealthyEnvelope(Data()))
        XCTAssertFalse(StartCommand.isHealthyEnvelope(Data(#"{"success":"true"}"#.utf8)), "a string is not a Bool")
    }

    func testTestRunnerEnvironmentKeysAreStable() {
        XCTAssertEqual(StartCommand.testRunnerEnvironment(port: 8299, token: "abc", isPhysical: false), [
            "TEST_RUNNER_SIMPILOT_PORT": "8299",
            "TEST_RUNNER_SIMPILOT_TOKEN": "abc",
            "TEST_RUNNER_SIMPILOT_BIND": "loopback"
        ])
        XCTAssertEqual(
            StartCommand.testRunnerEnvironment(port: 8222, token: "t", isPhysical: true)["TEST_RUNNER_SIMPILOT_BIND"],
            "all"
        )
    }

    func testIPv6HostIsBracketed() throws {
        let client = HTTPClient(host: "fd4d:85e2:eeb::1", port: 8222)
        XCTAssertEqual(client.baseURL, "http://[fd4d:85e2:eeb::1]:8222")
        let request = try client.makeRequest("/health", timeout: nil)
        XCTAssertEqual(request.url?.absoluteString, "http://[fd4d:85e2:eeb::1]:8222/health")
    }

    func testPerCallTimeoutOverridesTheDefault() throws {
        let client = HTTPClient(host: "127.0.0.1", port: 8222, timeout: 30)
        XCTAssertEqual(try client.makeRequest("/wait", timeout: 65).timeoutInterval, 65)
        XCTAssertEqual(try client.makeRequest("/wait", timeout: nil).timeoutInterval, 30)
    }

    func testUnbracketedIPv6BaseURLThrowsInvalidURL() {
        // The port suffix is ambiguous with IPv6 colons, so `URL(string:)`
        // rejects it — this is the failure `String.urlHost` exists to prevent.
        let client = HTTPClient(baseURL: "http://fd4d:85e2:eeb::1:8222")
        XCTAssertThrowsError(try client.makeRequest("/health", timeout: nil)) { error in
            guard case CLIError.invalidURL = error else {
                return XCTFail("expected invalidURL, got \(error)")
            }
        }
    }
}
