import XCTest
@testable import simpilot

final class ElementsCommandTests: XCTestCase {

    // MARK: - --type and --contains in query string

    func testTypeAppearsInQuery() throws {
        let path = try ElementsCommand.buildPath(from: ["--level", "1", "--type", "button,switch"])
        let params = queryParams(path)
        XCTAssertEqual(params["type"], "button,switch")
        XCTAssertEqual(params["level"], "1")
    }

    func testContainsAppearsInQuery() throws {
        let path = try ElementsCommand.buildPath(from: ["--level", "1", "--contains", "Settings"])
        let params = queryParams(path)
        XCTAssertEqual(params["contains"], "Settings")
    }

    func testTypeAndContainsCombined() throws {
        let path = try ElementsCommand.buildPath(from: [
            "--level", "1",
            "--type", "button",
            "--contains", "OK",
        ])
        let params = queryParams(path)
        XCTAssertEqual(params["type"], "button")
        XCTAssertEqual(params["contains"], "OK")
        XCTAssertEqual(params["level"], "1")
    }

    func testFiltersOmittedByDefault() throws {
        let path = try ElementsCommand.buildPath(from: ["--level", "1"])
        let params = queryParams(path)
        XCTAssertNil(params["type"])
        XCTAssertNil(params["contains"])
    }

    func testContainsWithReservedCharsEncoded() throws {
        let path = try ElementsCommand.buildPath(from: ["--contains", "A & B"])
        let params = queryParams(path)
        XCTAssertEqual(params["contains"], "A & B")
    }

    func testNoFlagsProducesBarePath() throws {
        let path = try ElementsCommand.buildPath(from: [])
        XCTAssertEqual(path, "/elements")
    }

    // MARK: - --format

    func testFormatOutlineAppearsInQuery() throws {
        let path = try ElementsCommand.buildPath(from: ["--format", "outline"])
        XCTAssertEqual(queryParams(path)["format"], "outline")
    }

    func testFormatIsOmittedByDefault() throws {
        let path = try ElementsCommand.buildPath(from: ["--level", "1"])
        XCTAssertNil(queryParams(path)["format"])
    }

    /// Rejected CLI-side so a typo exits 3 with a message naming the flag,
    /// instead of round-tripping to the agent for the same verdict.
    func testUnknownFormatIsRejected() {
        XCTAssertThrowsError(try ElementsCommand.buildPath(from: ["--format", "yaml"])) { error in
            guard case CLIError.invalidArgs(let message) = error else {
                return XCTFail("expected invalidArgs, got \(error)")
            }
            XCTAssertTrue(message.contains("--format"), message)
        }
    }

    /// `run` picks the plain-text path off the same flag `buildPath` encodes;
    /// they must not drift.
    func testIsOutlineTracksTheFlag() {
        XCTAssertTrue(ElementsCommand.isOutline(["--format", "outline"]))
        XCTAssertFalse(ElementsCommand.isOutline(["--format", "json"]))
        XCTAssertFalse(ElementsCommand.isOutline(["--level", "1"]))
    }

    /// Both sides normalize case, so `--format OUTLINE` cannot ask the agent for
    /// outline and then print the envelope instead of the text.
    func testFormatCaseIsNormalizedOnBothSides() throws {
        XCTAssertEqual(try queryParams(ElementsCommand.buildPath(from: ["--format", "OUTLINE"]))["format"], "outline")
        XCTAssertTrue(ElementsCommand.isOutline(["--format", "OUTLINE"]))
    }

    // MARK: - Helpers

    private func queryParams(_ path: String) -> [String: String] {
        guard let components = URLComponents(string: path) else { return [:] }
        var result: [String: String] = [:]
        for item in components.queryItems ?? [] {
            result[item.name] = item.value
        }
        return result
    }
}
