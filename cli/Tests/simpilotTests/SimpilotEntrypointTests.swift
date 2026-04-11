import XCTest
@testable import simpilot

/// Tests for `Simpilot.parseArguments(rawArgs:)` — the global option parser that
/// runs before any subcommand. Pins the contract that ArgParser-driven strict
/// validation runs before the `--help` short-circuit, so a malformed global flag
/// can't be hidden by a trailing `--help`.
final class SimpilotEntrypointTests: XCTestCase {

    // MARK: - Help routing

    func testBareHelpReturnsHelpCommand() throws {
        let opts = try Simpilot.parseArguments(rawArgs: ["--help"])
        XCTAssertEqual(opts.command, "help")
        XCTAssertEqual(opts.helpFormat, .text)
    }

    func testShortHelpAliasReturnsHelpCommand() throws {
        let opts = try Simpilot.parseArguments(rawArgs: ["-h"])
        XCTAssertEqual(opts.command, "help")
        XCTAssertEqual(opts.helpFormat, .text)
    }

    func testEmptyArgsReturnsHelpCommand() throws {
        let opts = try Simpilot.parseArguments(rawArgs: [])
        XCTAssertEqual(opts.command, "help")
    }

    // MARK: - Strict global parsing precedes --help short-circuit

    func testMalformedGlobalFlagBeforeHelpStillErrors() {
        // Old bug: `--port nope --help` printed help and exited 0 because the
        // help short-circuit ran before ArgParser.parse saw the bad --port value.
        XCTAssertThrowsError(
            try Simpilot.parseArguments(rawArgs: ["--port", "nope", "--help"])
        ) { error in
            assertInvalidArgs(error, contains: "--port")
            assertInvalidArgs(error, contains: "nope")
        }
    }

    func testMalformedTimeoutBeforeHelpStillErrors() {
        XCTAssertThrowsError(
            try Simpilot.parseArguments(rawArgs: ["--timeout", "soon", "--help"])
        ) { error in
            assertInvalidArgs(error, contains: "--timeout")
        }
    }

    func testUnknownGlobalFlagErrors() {
        XCTAssertThrowsError(
            try Simpilot.parseArguments(rawArgs: ["--bogus", "tap", "General"])
        ) { error in
            assertInvalidArgs(error, contains: "--bogus")
            assertInvalidArgs(error, contains: "simpilot")
        }
    }

    // MARK: - Valid global flags + subcommand split

    func testValidPortFlagThenCommand() throws {
        let opts = try Simpilot.parseArguments(rawArgs: ["--port", "8225", "tap", "General"])
        XCTAssertEqual(opts.port, 8225)
        XCTAssertEqual(opts.command, "tap")
        XCTAssertEqual(opts.commandArgs, ["General"])
    }

    func testPrettyAndTimeoutFlags() throws {
        let opts = try Simpilot.parseArguments(rawArgs: ["--pretty", "--timeout", "5", "health"])
        XCTAssertTrue(opts.pretty)
        XCTAssertEqual(opts.timeout, 5)
        XCTAssertEqual(opts.command, "health")
        XCTAssertEqual(opts.commandArgs, [])
    }

    func testCommandFlagsArePassedThrough() throws {
        // After the subcommand name, any flag is the subcommand's problem.
        // Global parser must NOT consume tap's --wait-until.
        let opts = try Simpilot.parseArguments(
            rawArgs: ["tap", "General", "--wait-until", "exists,hittable"]
        )
        XCTAssertEqual(opts.command, "tap")
        XCTAssertEqual(opts.commandArgs, ["General", "--wait-until", "exists,hittable"])
    }

    func testHelpAfterSubcommandIsSubcommandsProblem() throws {
        // `simpilot tap --help` should NOT trigger global help — the global
        // parser stops at "tap", and subcommand-local --help would be a
        // future feature. Today the subcommand will reject it as unknown.
        let opts = try Simpilot.parseArguments(rawArgs: ["tap", "--help"])
        XCTAssertEqual(opts.command, "tap")
        XCTAssertEqual(opts.commandArgs, ["--help"])
    }

    // MARK: - Helpers

    private func assertInvalidArgs(
        _ error: Error,
        contains needle: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case CLIError.invalidArgs(let msg) = error else {
            XCTFail("Expected CLIError.invalidArgs, got \(error)", file: file, line: line)
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

// MARK: - HelpFormat Equatable conformance for tests

extension HelpFormat: Equatable {
    public static func == (lhs: HelpFormat, rhs: HelpFormat) -> Bool {
        switch (lhs, rhs) {
        case (.json, .json), (.text, .text): return true
        default: return false
        }
    }
}
