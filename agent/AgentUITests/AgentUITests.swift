import XCTest

// This class owns `simpilot start`'s runtime entry point: `testAgent` runs
// forever as an HTTP server hosted inside XCUITest. Do **not** run this class
// from `xcodebuild test` without a filter — it never returns. Use
// `-only-testing:AgentUITests/<UnitTestClass>` to run the pure-logic suites
// (StablePredicateTests / PredicateEvaluatorTests / DebugDescriptionParserTests).
final class AgentUITests: XCTestCase {
    func testAgent() throws {
        var port: UInt16 = 8222

        // Try environment variable first (set by xcodebuild's scheme or process env)
        if let envPort = ProcessInfo.processInfo.environment["SIMPILOT_PORT"],
           let p = UInt16(envPort) {
            port = p
        }
        // Fallback: read port from file written by CLI (keyed by simulator UDID)
        else if let udid = ProcessInfo.processInfo.environment["SIMULATOR_UDID"] {
            let portFile = "/tmp/simpilot-port-\(udid)"
            if let contents = try? String(contentsOfFile: portFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               let p = UInt16(contents) {
                port = p
            }
        }

        let server = HTTPServer(port: port)
        server.start()

        print("[simpilot] Agent started on port \(port)")

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
