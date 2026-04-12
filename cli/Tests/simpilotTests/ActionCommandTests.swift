import XCTest
@testable import simpilot

final class ActionCommandTests: XCTestCase {

    // MARK: - --element requires --screenshot

    func testElementWithoutScreenshotIsRejected() {
        XCTAssertThrowsError(
            try ActionCommand.parseAndValidate(["tap", "General", "--element", "button:OK"])
        ) { error in
            assertInvalidArgs(error, contains: "--element requires --screenshot")
        }
    }

    func testElementWithScreenshotIsAccepted() throws {
        let parsed = try ActionCommand.parseAndValidate([
            "tap", "General",
            "--screenshot", "/tmp/s.png",
            "--element", "button:OK",
        ])
        XCTAssertEqual(parsed.string("--screenshot"), "/tmp/s.png")
        XCTAssertEqual(parsed.string("--element"), "button:OK")
    }

    func testNoElementNoScreenshotIsAccepted() throws {
        let parsed = try ActionCommand.parseAndValidate(["tap", "General"])
        XCTAssertNil(parsed.string("--element"))
        XCTAssertNil(parsed.string("--screenshot"))
    }

    func testScreenshotWithoutElementIsAccepted() throws {
        let parsed = try ActionCommand.parseAndValidate([
            "tap", "General",
            "--screenshot", "/tmp/s.png",
        ])
        XCTAssertEqual(parsed.string("--screenshot"), "/tmp/s.png")
        XCTAssertNil(parsed.string("--element"))
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
