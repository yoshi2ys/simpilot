import XCTest
@testable import simpilot

/// Tests `StartCommand.resolveMultiMode` — the parse+validate step that owns
/// the `--clone`/`--create` invariants. Old code's `parseOptionalCount` only
/// consumed `n > 0`; the new declarative parser accepts any Int, so the
/// command-level validator must reject 0 / negative counts (otherwise
/// `for _ in 0..<count` would either no-op silently or crash).
final class StartCommandTests: XCTestCase {

    func testNoFlagsResolvesToSingleMode() throws {
        let (device, mode) = try StartCommand.resolveMultiMode(args: [])
        XCTAssertEqual(device, "iPhone 17 Pro")
        XCTAssertNil(mode)
    }

    func testDeviceFlagOverridesDefault() throws {
        let (device, mode) = try StartCommand.resolveMultiMode(args: ["--device", "iPhone Air"])
        XCTAssertEqual(device, "iPhone Air")
        XCTAssertNil(mode)
    }

    func testCloneWithPositiveCount() throws {
        let (_, mode) = try StartCommand.resolveMultiMode(args: ["--clone", "3"])
        XCTAssertEqual(mode, .clone(3))
    }

    func testCloneWithoutValueDefaultsToOne() throws {
        let (_, mode) = try StartCommand.resolveMultiMode(args: ["--clone"])
        XCTAssertEqual(mode, .clone(1))
    }

    func testCreateWithPositiveCount() throws {
        let (_, mode) = try StartCommand.resolveMultiMode(args: ["--create", "2"])
        XCTAssertEqual(mode, .create(2))
    }

    func testCloneZeroIsRejected() {
        XCTAssertThrowsError(try StartCommand.resolveMultiMode(args: ["--clone", "0"])) { error in
            assertInvalidArgs(error, contains: "--clone")
            assertInvalidArgs(error, contains: "positive")
            assertInvalidArgs(error, contains: "0")
        }
    }

    func testCloneNegativeIsRejected() {
        XCTAssertThrowsError(try StartCommand.resolveMultiMode(args: ["--clone", "-3"])) { error in
            assertInvalidArgs(error, contains: "--clone")
            assertInvalidArgs(error, contains: "positive")
            assertInvalidArgs(error, contains: "-3")
        }
    }

    func testCreateZeroIsRejected() {
        XCTAssertThrowsError(try StartCommand.resolveMultiMode(args: ["--create", "0"])) { error in
            assertInvalidArgs(error, contains: "--create")
            assertInvalidArgs(error, contains: "positive")
        }
    }

    func testCloneAndCreateMutuallyExclusive() {
        XCTAssertThrowsError(
            try StartCommand.resolveMultiMode(args: ["--clone", "2", "--create", "2"])
        ) { error in
            assertInvalidArgs(error, contains: "mutually exclusive")
        }
    }

    func testCloneFooRejectedAsNonInteger() {
        XCTAssertThrowsError(try StartCommand.resolveMultiMode(args: ["--clone", "foo"])) { error in
            assertInvalidArgs(error, contains: "--clone")
            assertInvalidArgs(error, contains: "foo")
        }
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
