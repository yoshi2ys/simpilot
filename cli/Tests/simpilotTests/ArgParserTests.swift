import XCTest
@testable import simpilot

final class ArgParserTests: XCTestCase {

    // MARK: - Spec helpers

    private let tapSpec = ArgSpec(
        command: "tap",
        positionals: [.init(name: "query", required: true)],
        flags: [
            .init("--wait-until", .string),
            .init("--timeout", .double),
            .init("--poll-interval", .int),
        ]
    )

    private let startSpec = ArgSpec(
        command: "start",
        flags: [
            .init("--device", .string),
            .init("--clone", .optionalInt(default: 1)),
            .init("--create", .optionalInt(default: 1)),
        ]
    )

    private let stopSpec = ArgSpec(
        command: "stop",
        flags: [
            .init("--port", .int),
            .init("--udid", .string),
            .init("--all", .bool),
        ]
    )

    private let typeSpec = ArgSpec(
        command: "type",
        positionals: [.init(name: "text", required: true)],
        flags: [
            .init("--into", .string),
            .init("--method", .string),
        ]
    )

    private let assertSpec = ArgSpec(
        command: "assert",
        positionals: [
            .init(name: "predicate", required: true),
            .init(name: "query", required: true),
            .init(name: "expected", required: false),
        ],
        flags: [
            .init("--timeout", .double),
            .init("--snapshot-on-fail", .bool),
        ]
    )

    private let batchSpec = ArgSpec(
        command: "batch",
        positionals: [.init(name: "json", required: false)],
        allowsExtraPositionals: true
    )

    // MARK: - Known flag parsing

    func testParsesPositionalAndStringFlag() throws {
        let parsed = try ArgParser.parse(["General", "--wait-until", "exists,hittable"], spec: tapSpec)
        XCTAssertEqual(parsed.positionals, ["General"])
        XCTAssertEqual(parsed.string("--wait-until"), "exists,hittable")
        XCTAssertNil(parsed.double("--timeout"))
        XCTAssertNil(parsed.int("--poll-interval"))
    }

    func testParsesIntAndDoubleFlags() throws {
        let parsed = try ArgParser.parse(
            ["General", "--timeout", "5.5", "--poll-interval", "200"],
            spec: tapSpec
        )
        XCTAssertEqual(parsed.double("--timeout"), 5.5)
        XCTAssertEqual(parsed.int("--poll-interval"), 200)
    }

    func testBoolFlagDefaultsFalseAndSetsTrueWhenPresent() throws {
        let off = try ArgParser.parse(["exists", "General"], spec: assertSpec)
        XCTAssertFalse(off.bool("--snapshot-on-fail"))

        let on = try ArgParser.parse(["exists", "General", "--snapshot-on-fail"], spec: assertSpec)
        XCTAssertTrue(on.bool("--snapshot-on-fail"))
    }

    func testInterleavedFlagsAndPositionals() throws {
        let parsed = try ArgParser.parse(
            ["exists", "--timeout", "2", "General"],
            spec: assertSpec
        )
        XCTAssertEqual(parsed.positionals, ["exists", "General"])
        XCTAssertEqual(parsed.double("--timeout"), 2.0)
    }

    // MARK: - Strict rejection

    func testUnknownFlagIsRejected() {
        XCTAssertThrowsError(try ArgParser.parse(["General", "--bogus"], spec: tapSpec)) { error in
            assertInvalidArgs(error, contains: "--bogus")
            assertInvalidArgs(error, contains: "tap")
        }
    }

    func testMissingValueForStringFlag() {
        XCTAssertThrowsError(try ArgParser.parse(["General", "--wait-until"], spec: tapSpec)) { error in
            assertInvalidArgs(error, contains: "requires a value")
        }
    }

    func testMissingValueForDoubleFlag() {
        XCTAssertThrowsError(try ArgParser.parse(["General", "--timeout"], spec: tapSpec)) { error in
            assertInvalidArgs(error, contains: "requires a value")
        }
    }

    func testIntFlagRejectsNonNumeric() {
        XCTAssertThrowsError(try ArgParser.parse(["General", "--poll-interval", "fast"], spec: tapSpec)) { error in
            assertInvalidArgs(error, contains: "expects an integer")
            assertInvalidArgs(error, contains: "fast")
        }
    }

    func testDoubleFlagRejectsNonNumeric() {
        XCTAssertThrowsError(try ArgParser.parse(["General", "--timeout", "soon"], spec: tapSpec)) { error in
            assertInvalidArgs(error, contains: "expects a number")
        }
    }

    func testMissingRequiredPositional() {
        XCTAssertThrowsError(try ArgParser.parse([], spec: tapSpec)) { error in
            assertInvalidArgs(error, contains: "missing required argument")
            assertInvalidArgs(error, contains: "<query>")
        }
    }

    func testExtraPositionalRejected() {
        XCTAssertThrowsError(try ArgParser.parse(["General", "foo"], spec: tapSpec)) { error in
            assertInvalidArgs(error, contains: "unexpected argument")
            assertInvalidArgs(error, contains: "'foo'")
            assertInvalidArgs(error, contains: "<query>")
        }
    }

    func testNoPositionalsAllowedRejectsAny() {
        let healthSpec = ArgSpec(command: "health")
        XCTAssertThrowsError(try ArgParser.parse(["foo"], spec: healthSpec)) { error in
            assertInvalidArgs(error, contains: "no positional")
        }
    }

    // MARK: - POSIX `--` terminator

    func testDoubleDashTerminatorPushesFlagsAsPositional() throws {
        let parsed = try ArgParser.parse(["--", "--method"], spec: typeSpec)
        XCTAssertEqual(parsed.positionals, ["--method"])
        XCTAssertNil(parsed.string("--method"))
    }

    func testFlagsBeforeTerminatorStillParsed() throws {
        let parsed = try ArgParser.parse(["--into", "Email", "--", "--literal-text"], spec: typeSpec)
        XCTAssertEqual(parsed.string("--into"), "Email")
        XCTAssertEqual(parsed.positionals, ["--literal-text"])
    }

    func testEmDashIsTreatedAsPositionalNotFlag() throws {
        // U+2014 EM DASH should not be confused with `--`. Treated as positional.
        let parsed = try ArgParser.parse(["\u{2014}fancy"], spec: typeSpec)
        XCTAssertEqual(parsed.positionals, ["\u{2014}fancy"])
    }

    func testEqualsSyntaxIsNotSupportedAndRejected() {
        // We deliberately don't support GNU-style `--flag=value`. Pin the
        // rejection so a future contributor either adds explicit support or
        // sees a clear "unknown flag" error instead of silent breakage.
        XCTAssertThrowsError(try ArgParser.parse(["General", "--timeout=5"], spec: tapSpec)) { error in
            assertInvalidArgs(error, contains: "--timeout=5")
        }
    }

    // MARK: - optionalInt

    func testOptionalIntWithoutValueUsesDefault() throws {
        let parsed = try ArgParser.parse(["--clone"], spec: startSpec)
        XCTAssertEqual(parsed.int("--clone"), 1)
    }

    func testOptionalIntWithValueConsumesIt() throws {
        let parsed = try ArgParser.parse(["--clone", "3"], spec: startSpec)
        XCTAssertEqual(parsed.int("--clone"), 3)
    }

    func testOptionalIntFollowedByAnotherFlag() throws {
        let parsed = try ArgParser.parse(["--clone", "--device", "iPhone Air"], spec: startSpec)
        XCTAssertEqual(parsed.int("--clone"), 1)
        XCTAssertEqual(parsed.string("--device"), "iPhone Air")
    }

    func testOptionalIntRejectsNonNumericValue() {
        // Acceptance criterion 2.1 #2: `simpilot start --clone foo` → exit 3.
        XCTAssertThrowsError(try ArgParser.parse(["--clone", "foo"], spec: startSpec)) { error in
            assertInvalidArgs(error, contains: "--clone")
            assertInvalidArgs(error, contains: "foo")
        }
    }

    func testOptionalIntFollowedByTerminatorUsesDefault() throws {
        // `start --clone --` → clone=1, no positionals after terminator.
        let parsed = try ArgParser.parse(["--clone", "--"], spec: startSpec)
        XCTAssertEqual(parsed.int("--clone"), 1)
        XCTAssertEqual(parsed.positionals, [])
    }

    // MARK: - Variadic positionals (batch)

    func testVariadicAllowsMultiplePositionals() throws {
        let parsed = try ArgParser.parse(["{\"key\":", "\"value\"}"], spec: batchSpec)
        XCTAssertEqual(parsed.positionals, ["{\"key\":", "\"value\"}"])
    }

    func testVariadicAllowsZeroPositionals() throws {
        let parsed = try ArgParser.parse([], spec: batchSpec)
        XCTAssertEqual(parsed.positionals, [])
    }

    // MARK: - assert (3-positional layout)

    func testAssertWithExpectedValue() throws {
        let parsed = try ArgParser.parse(["value", "Email", "contains:foo"], spec: assertSpec)
        XCTAssertEqual(parsed.positionals, ["value", "Email", "contains:foo"])
    }

    func testAssertRejectsFourthPositional() {
        XCTAssertThrowsError(
            try ArgParser.parse(["value", "Email", "contains:foo", "extra"], spec: assertSpec)
        ) { error in
            assertInvalidArgs(error, contains: "unexpected argument")
            assertInvalidArgs(error, contains: "'extra'")
        }
    }

    // MARK: - stop spec
    //
    // These exercise ArgParser against a representative spec for `stop`. The real
    // StopCommand isn't migrated until Wave 2.2 — these pin the contract the future
    // StopCommand will rely on, not the live CLI behavior.

    func testStopAcceptsPortFlag() throws {
        let parsed = try ArgParser.parse(["--port", "8223"], spec: stopSpec)
        XCTAssertEqual(parsed.int("--port"), 8223)
        XCTAssertNil(parsed.string("--udid"))
        XCTAssertFalse(parsed.bool("--all"))
    }

    func testStopAcceptsAllFlag() throws {
        let parsed = try ArgParser.parse(["--all"], spec: stopSpec)
        XCTAssertTrue(parsed.bool("--all"))
    }

    func testStopRejectsUnknownFlag() {
        XCTAssertThrowsError(try ArgParser.parse(["--force"], spec: stopSpec)) { error in
            assertInvalidArgs(error, contains: "--force")
        }
    }

    // MARK: - Helpers

    private func assertInvalidArgs(_ error: Error, contains needle: String, file: StaticString = #filePath, line: UInt = #line) {
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
