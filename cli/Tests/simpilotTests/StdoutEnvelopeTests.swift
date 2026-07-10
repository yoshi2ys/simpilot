import Foundation
import XCTest
@testable import simpilot

/// A31's contract: **a command that receives an agent envelope writes exactly
/// one JSON object to stdout**, whether it succeeds or fails.
///
/// simpilot's first consumer is an AI agent running `json.loads(stdout)`. A
/// failing command used to print the agent's envelope and then a second,
/// CLI-generated one — so stdout held two objects, `json.loads` raised
/// `Extra data`, and the agent's specific code (`element_not_found`) was
/// buried under a generic `command_failed`.
///
/// The contract is scoped to envelopes on purpose: `decodeAndPrint` still
/// passes a non-JSON agent response through verbatim and exits 0. That path
/// predates A31 and is tracked separately.
///
/// The end-to-end cases spawn the real binary against a stub agent, because the
/// bug lived in the seam between `decodeAndPrint` (which prints) and
/// `main` (which printed again) — no in-process call crosses it.
final class StdoutEnvelopeTests: XCTestCase {

    // MARK: - Exit-status mapping (pure)

    func testSuccessEnvelopeYieldsNoFailureStatus() {
        XCTAssertNil(agentFailureStatus(in: ["success": true, "data": ["x": 1]]))
    }

    func testFailureEnvelopeExitsTwo() {
        let json: [String: Any] = [
            "success": false,
            "error": ["code": "element_not_found", "message": "no such element"],
        ]
        XCTAssertEqual(agentFailureStatus(in: json), 2)
    }

    func testInvalidRegexExitsThreeLikeACLISideArgError() {
        let json: [String: Any] = [
            "success": false,
            "error": ["code": "invalid_regex", "message": "bad pattern"],
        ]
        XCTAssertEqual(agentFailureStatus(in: json), 3)
    }

    func testFailureWithoutAnErrorObjectStillExitsTwo() {
        XCTAssertEqual(agentFailureStatus(in: ["success": false]), 2)
    }

    /// Pins the existing contract. Unreachable against a real agent —
    /// `HTTPResponse` puts `success` in every envelope it builds — so this
    /// documents the fallback rather than endorsing it.
    func testEnvelopeWithoutSuccessKeyReadsAsSuccess() {
        XCTAssertNil(agentFailureStatus(in: ["data": ["x": 1]]))
    }

    func testDecodeAndPrintThrowsAlreadyReportedRatherThanACLIError() throws {
        let body = Data(#"{"success":false,"error":{"code":"element_not_found","message":"nope"}}"#.utf8)
        XCTAssertThrowsError(try decodeAndPrint(data: body, pretty: false)) { error in
            guard let reported = error as? AlreadyReported else {
                return XCTFail("a CLIError here makes main print a second envelope: \(error)")
            }
            XCTAssertEqual(reported.status, 2)
        }
    }

    // MARK: - End-to-end: one JSON object on stdout

    func testFailingCommandPrintsOneObjectAndKeepsTheAgentErrorCode() throws {
        let agent = try StubAgent(responseBody: Self.failureEnvelope)
        defer { agent.stop() }

        let result = try runCLI(["--port", "\(agent.port)", "tap", "NoSuchElement"])

        XCTAssertEqual(result.status, 2)
        let json = try singleJSONObject(from: result.stdout)
        let error = try XCTUnwrap(json["error"] as? [String: Any])
        XCTAssertEqual(
            error["code"] as? String, "element_not_found",
            "the agent's code must survive; a second envelope would degrade it to command_failed"
        )
        XCTAssertEqual(json["duration_ms"] as? Int, 12, "the agent's envelope must reach stdout intact")
    }

    /// `--pretty` used to mix a multi-line object with a compact one.
    func testPrettyFailureIsStillASingleObject() throws {
        let agent = try StubAgent(responseBody: Self.failureEnvelope)
        defer { agent.stop() }

        let result = try runCLI(["--port", "\(agent.port)", "--pretty", "health"])

        XCTAssertEqual(result.status, 2)
        let json = try singleJSONObject(from: result.stdout)
        XCTAssertEqual(json["success"] as? Bool, false)
        XCTAssertTrue(result.stdout.contains("\n  "), "expected pretty-printed output, got: \(result.stdout)")
    }

    func testInvalidRegexFromTheAgentExitsThree() throws {
        let agent = try StubAgent(
            responseBody: #"{"success":false,"data":null,"duration_ms":1,"error":{"code":"invalid_regex","message":"bad pattern"}}"#
        )
        defer { agent.stop() }

        let result = try runCLI(["--port", "\(agent.port)", "elements"])

        XCTAssertEqual(result.status, 3)
        let json = try singleJSONObject(from: result.stdout)
        let error = try XCTUnwrap(json["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "invalid_regex")
    }

    func testSuccessfulCommandStillExitsZeroWithOneObject() throws {
        let agent = try StubAgent(responseBody: #"{"success":true,"data":{"status":"ok"},"duration_ms":3,"error":null}"#)
        defer { agent.stop() }

        let result = try runCLI(["--port", "\(agent.port)", "health"])

        XCTAssertEqual(result.status, 0)
        let json = try singleJSONObject(from: result.stdout)
        XCTAssertEqual(json["success"] as? Bool, true)
    }

    // MARK: - End-to-end: `run` keeps its report unpolluted

    /// `run` already dodged the double envelope with a bare `exit()`. It now
    /// throws `AlreadyReported` like every other command; the observable
    /// behavior must not move.
    func testFailingScenarioJSONReportIsTheOnlyObjectOnStdout() throws {
        let agent = try StubAgent(responseBody: Self.failureEnvelope)
        defer { agent.stop() }
        let scenario = try writeScenario()

        let result = try runCLI(["--port", "\(agent.port)", "run", scenario.path, "--json"])

        XCTAssertEqual(result.status, 2)
        let json = try singleJSONObject(from: result.stdout)
        XCTAssertEqual(json["success"] as? Bool, false)
        let data = try XCTUnwrap(json["data"] as? [String: Any])
        XCTAssertEqual(data["total_failed"] as? Int, 1)
    }

    func testFailingScenarioTerminalReportGetsNoErrorEnvelope() throws {
        let agent = try StubAgent(responseBody: Self.failureEnvelope)
        defer { agent.stop() }
        let scenario = try writeScenario()

        let result = try runCLI(["--port", "\(agent.port)", "run", scenario.path])

        XCTAssertEqual(result.status, 2)
        XCTAssertFalse(
            result.stdout.contains("command_failed"),
            "terminal mode must stay human-readable: \(result.stdout)"
        )
    }

    // MARK: - Helpers

    private static let failureEnvelope =
        #"{"success":false,"data":null,"duration_ms":12,"error":{"code":"element_not_found","message":"no such element"}}"#

    /// The exact check an AI client performs: `json.loads(stdout)`.
    /// `JSONSerialization` rejects a second object as trailing garbage, so a
    /// successful parse *is* the "exactly one object" assertion.
    private func singleJSONObject(from stdout: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: Data(stdout.utf8))
        } catch {
            XCTFail("stdout is not a single JSON object (\(error)):\n\(stdout)", file: file, line: line)
            throw error
        }
        guard let dict = parsed as? [String: Any] else {
            XCTFail("expected a JSON object, got \(type(of: parsed))", file: file, line: line)
            throw CocoaError(.propertyListReadCorrupt)
        }
        return dict
    }

    /// `swift test` builds the executable target the test bundle depends on, so
    /// the binary sits beside the test bundle in `.build/debug`.
    private static let binaryURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // simpilotTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // cli
        .appendingPathComponent(".build/debug/simpilot")

    private func runCLI(_ args: [String], file: StaticString = #filePath, line: UInt = #line) throws -> (stdout: String, status: Int32) {
        guard FileManager.default.isExecutableFile(atPath: Self.binaryURL.path) else {
            XCTFail("simpilot binary not found at \(Self.binaryURL.path); run `swift build` first", file: file, line: line)
            throw CocoaError(.fileNoSuchFile)
        }

        // An empty registry home keeps the test off the developer's real agents:
        // no record for the port means no token and a loopback host.
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("simpilot-a31-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        var environment = ProcessInfo.processInfo.environment
        environment["SIMPILOT_HOME"] = home.path
        environment.removeValue(forKey: "SIMPILOT_PORT")

        let process = Process()
        process.executableURL = Self.binaryURL
        process.arguments = args
        process.environment = environment
        let stdout = Pipe()
        process.standardOutput = stdout
        // Not a Pipe: nothing here reads stderr, and an undrained pipe blocks the
        // child once its buffer fills — the child would then never close stdout
        // and the read below would never see EOF.
        process.standardError = FileHandle.nullDevice
        try process.run()

        // Drain before waiting: a full pipe buffer would deadlock the child (A7).
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), process.terminationStatus)
    }

    /// One always-failing step. `screenshot_on_failure` is off so the run makes
    /// exactly one request and writes no files.
    private func writeScenario() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("simpilot-a31-\(UUID().uuidString).yaml")
        let yaml = """
        name: A31 double envelope
        config:
          screenshot_on_failure: false
        scenarios:
          - name: tap a missing element
            steps:
              - tap: NoSuchElement
        """
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}

/// An HTTP server that answers every request with the same envelope. Enough to
/// drive the CLI's response-handling path without a simulator.
private final class StubAgent: @unchecked Sendable {
    let port: UInt16
    private let listenFD: Int32
    private let response: Data
    private let queue = DispatchQueue(label: "stub-agent")

    init(responseBody: String) throws {
        let body = Data(responseBody.utf8)
        // The two trailing empties close the header block with a bare CRLF.
        let head = [
            "HTTP/1.1 200 OK",
            "Content-Type: application/json",
            "Content-Length: \(body.count)",
            "Connection: close",
            "", "",
        ].joined(separator: "\r\n")
        response = Data(head.utf8) + body

        let listener = try EphemeralTCPListener(backlog: 8)
        listenFD = listener.fd
        port = listener.port

        // Locals, not properties: the closure must not capture a half-built self.
        let fd = listener.fd
        let responseBytes = response
        queue.async {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return } // stop() closed the listener
                StubAgent.serve(client, response: responseBytes)
            }
        }
    }

    func stop() {
        close(listenFD) // unblocks the accept loop
    }

    private static func serve(_ client: Int32, response: Data) {
        defer { close(client) }
        // Writing to a peer that hung up must not kill the test process.
        var yes: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

        // Consume the whole request before replying: closing on an unread body
        // would surface to the client as a connection error, not a response.
        guard readRequest(client) else { return }
        response.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let n = send(client, buffer.baseAddress!.advanced(by: sent), buffer.count - sent, 0)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return } // peer hung up
                sent += n
            }
        }
    }

    /// Reads headers, then `Content-Length` body bytes. Returns false if the
    /// peer hung up first.
    private static func readRequest(_ client: Int32) -> Bool {
        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let terminator = Data("\r\n\r\n".utf8)

        while true {
            if let headerEnd = received.range(of: terminator) {
                let header = String(decoding: received[..<headerEnd.lowerBound], as: UTF8.self)
                if received.count - headerEnd.upperBound >= contentLength(in: header) { return true }
            }
            let n = recv(client, &chunk, chunk.count, 0)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return false } // peer hung up
            received.append(contentsOf: chunk[0..<n])
        }
    }

    private static func contentLength(in header: String) -> Int {
        for line in header.lowercased().split(separator: "\n") {
            guard line.hasPrefix("content-length:") else { continue }
            return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        return 0
    }
}
