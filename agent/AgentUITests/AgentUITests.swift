import XCTest

final class AgentUITests: XCTestCase {
    func testAgent() throws {
        var port: UInt16 = 8222
        if let envPort = ProcessInfo.processInfo.environment["SIMPILOT_PORT"],
           let p = UInt16(envPort) {
            port = p
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
