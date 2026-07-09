import XCTest
@testable import simpilot

/// Runtime-layer coverage for the scenario runner: timeout arithmetic, envelope
/// interpretation, stop-on-failure sequencing, screenshot naming, and the
/// pass/fail tallies `simpilot run` turns into an exit code.
final class ScenarioRuntimeTests: XCTestCase {

    // MARK: - computeHTTPTimeout

    func testHTTPTimeoutAddsTheBufferToTheConfigTimeout() {
        let config = ScenarioConfig(timeout: 5)
        XCTAssertEqual(
            StepExecutor.computeHTTPTimeout(config: config, stepTimeout: nil),
            5 + HTTPClient.operationBuffer
        )
    }

    func testHTTPTimeoutHonorsALongerStepTimeout() {
        let config = ScenarioConfig(timeout: 5)
        XCTAssertEqual(
            StepExecutor.computeHTTPTimeout(config: config, stepTimeout: 60),
            60 + HTTPClient.operationBuffer,
            "a `wait` step with a 60s budget must not be cut off at the 5s scenario default"
        )
    }

    func testHTTPTimeoutNeverDropsBelowTheConfigTimeout() {
        let config = ScenarioConfig(timeout: 30)
        XCTAssertEqual(
            StepExecutor.computeHTTPTimeout(config: config, stepTimeout: 1),
            30 + HTTPClient.operationBuffer
        )
    }

    // MARK: - Envelope interpretation

    func testIsSuccessRequiresAnExplicitTrue() {
        XCTAssertTrue(StepExecutor.isSuccess(["success": true]))
        XCTAssertFalse(StepExecutor.isSuccess(["success": false]))
        XCTAssertFalse(StepExecutor.isSuccess([:]), "a missing `success` field is malformed, not a pass")
        XCTAssertFalse(StepExecutor.isSuccess(["success": "true"]), "a string is not a Bool")
    }

    func testErrorMessagePrefersMessageThenCode() {
        XCTAssertEqual(
            StepExecutor.errorMessage(["error": ["code": "element_not_found", "message": "no such element"]]),
            "no such element"
        )
        XCTAssertEqual(
            StepExecutor.errorMessage(["error": ["code": "element_not_found"]]),
            "element_not_found"
        )
        XCTAssertNil(StepExecutor.errorMessage(["error": NSNull()]))
        XCTAssertNil(StepExecutor.errorMessage([:]))
    }

    func testParseResponseRejectsNonJSON() {
        XCTAssertThrowsError(try StepExecutor.parseResponse(Data("<html>502</html>".utf8))) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("non-JSON"),
                "the raw body must appear in the error: \(error.localizedDescription)"
            )
        }
    }

    func testParseResponseAcceptsAnEnvelope() throws {
        let json = try StepExecutor.parseResponse(Data(#"{"success":true,"data":{}}"#.utf8))
        XCTAssertEqual(json["success"] as? Bool, true)
    }

    // MARK: - Failure screenshot naming

    func testFailureScreenshotNameIsSanitizedAndOneBased() {
        XCTAssertEqual(
            ScenarioRunner.failureScreenshotFileName(scenarioName: "Open About", stepIndex: 0),
            "Open_About_step1.png"
        )
        XCTAssertEqual(
            ScenarioRunner.failureScreenshotFileName(scenarioName: "a/b c", stepIndex: 2),
            "a_b_c_step3.png",
            "slashes must not escape the screenshot directory"
        )
    }

    // MARK: - stop-on-failure sequencing

    /// A client pointed at a closed port: any step that makes an HTTP call fails
    /// with `agent_unreachable`, so the runner can be driven without a live agent.
    private func unreachableClient() -> HTTPClient {
        HTTPClient(baseURL: "http://127.0.0.1:1", timeout: 1)
    }

    /// `tap` reaches for the client (and fails); `sleep` completes locally.
    /// Both take the same path through the runner otherwise.
    private func scenarioFile(
        of action: StepAction,
        steps stepCount: Int = 3,
        stopOnFailure: Bool = true
    ) -> ScenarioFile {
        var config = ScenarioConfig()
        config.stopOnFailure = stopOnFailure
        config.screenshotOnFailure = false // don't shell out to a dead agent
        config.timeout = 1
        let steps = (1...stepCount).map { Step(action: action, stepNumber: $0) }
        return ScenarioFile(
            name: "t.yaml", config: config, variables: [:],
            scenarios: [Scenario(name: "s", steps: steps)]
        )
    }

    private static let failingStep = StepAction.tap(query: "X", waitUntil: nil, timeout: nil)

    func testStopOnFailureSkipsRemainingSteps() {
        let result = ScenarioRunner.run(
            file: scenarioFile(of: Self.failingStep),
            client: unreachableClient()
        )
        XCTAssertEqual(result.scenarioResults[0].stepResults.map(\.status), [.failed, .skipped, .skipped])
        XCTAssertEqual(result.totalFailed, 1)
        XCTAssertEqual(result.totalSkipped, 2)
        XCTAssertEqual(result.totalPassed, 0)
        XCTAssertFalse(result.scenarioResults[0].passed)
    }

    func testWithoutStopOnFailureEveryStepRuns() {
        let result = ScenarioRunner.run(
            file: scenarioFile(of: Self.failingStep, stopOnFailure: false),
            client: unreachableClient()
        )
        XCTAssertEqual(result.scenarioResults[0].stepResults.map(\.status), [.failed, .failed, .failed])
        XCTAssertEqual(result.totalSkipped, 0)
    }

    func testUnreachableAgentIsReportedAsSuch() {
        let result = ScenarioRunner.run(
            file: scenarioFile(of: Self.failingStep, steps: 1),
            client: unreachableClient()
        )
        let error = result.scenarioResults[0].stepResults[0].error ?? ""
        XCTAssertTrue(error.contains("agent unreachable"), error)
    }

    func testAllStepsPassingLeavesNoFailures() {
        let result = ScenarioRunner.run(
            file: scenarioFile(of: .sleep(seconds: 0)),
            client: unreachableClient()
        )
        XCTAssertEqual(result.totalPassed, 3)
        XCTAssertEqual(result.totalFailed, 0)
        XCTAssertTrue(result.scenarioResults[0].passed)
    }
}
