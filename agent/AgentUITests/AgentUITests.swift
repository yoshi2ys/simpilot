import XCTest

// This class owns `simpilot start`'s runtime entry point: `testAgent` runs
// forever as an HTTP server hosted inside XCUITest. Do **not** run this class
// from `xcodebuild test` without a filter — it never returns. Use
// `-only-testing:AgentUITests/<UnitTestClass>` to run the pure-logic suites
// (StablePredicateTests / PredicateEvaluatorTests / DebugDescriptionParserTests).
final class AgentUITests: XCTestCase {
    func testAgent() throws {
        // `simpilot start` passes port/bind/token as TEST_RUNNER_* variables,
        // which xcodebuild forwards into this process's environment. A bad or
        // unsafe combination fails the test loudly rather than falling back to
        // a silently different listener.
        let config: AgentConfig
        do {
            config = try AgentConfig.resolve(env: ProcessInfo.processInfo.environment)
        } catch {
            XCTFail("[simpilot] Agent configuration rejected: \(error)")
            return
        }

        let server = HTTPServer(config: config)
        server.start()

        print("[simpilot] Agent started on port \(config.port)")

        // Run the main RunLoop forever, with ObjC exception protection.
        // XCUITest can throw NSException asynchronously (e.g., during UI hierarchy updates
        // after navigation). Without this protection, unhandled exceptions in RunLoop
        // callbacks would crash the entire test runner process.
        while true {
            let exceptionMsg = catchObjCException {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 1))
            }
            if let exceptionMsg {
                print("[simpilot] Caught async exception in RunLoop: \(exceptionMsg)")
            }
        }
    }
}
