import XCTest
@testable import simpilot

final class ScreenshotCommandTests: XCTestCase {

    // MARK: - --element in query string

    func testElementAppearsInQueryString() throws {
        let path = try ScreenshotCommand.buildPath(from: ["--element", "button:OK"])
        let params = queryParams(path)
        XCTAssertEqual(params["element"], "button:OK")
        XCTAssertEqual(params["scale"], "1")
    }

    func testElementOmittedFromQueryWhenAbsent() throws {
        let path = try ScreenshotCommand.buildPath(from: [])
        let params = queryParams(path)
        XCTAssertNil(params["element"])
        XCTAssertEqual(params["scale"], "1")
    }

    func testElementCombinedWithFileAndScale() throws {
        let path = try ScreenshotCommand.buildPath(from: [
            "--file", "/tmp/s.png",
            "--scale", "native",
            "--element", "General",
        ])
        let params = queryParams(path)
        XCTAssertEqual(params["scale"], "native")
        XCTAssertEqual(params["file"], "/tmp/s.png")
        XCTAssertEqual(params["element"], "General")
    }

    func testDefaultScaleWhenOnlyElement() throws {
        let path = try ScreenshotCommand.buildPath(from: ["--element", "General"])
        let params = queryParams(path)
        XCTAssertEqual(params["scale"], "1")
        XCTAssertEqual(params["element"], "General")
    }

    // MARK: - Reserved characters in element query

    func testElementWithAmpersandIsEncodedCorrectly() throws {
        let path = try ScreenshotCommand.buildPath(from: ["--element", "A & B"])
        let params = queryParams(path)
        XCTAssertEqual(params["element"], "A & B")
        XCTAssertEqual(params.count, 2, "Only scale + element expected")
    }

    func testElementWithEqualsIsEncodedCorrectly() throws {
        let path = try ScreenshotCommand.buildPath(from: ["--element", "foo=bar"])
        let params = queryParams(path)
        XCTAssertEqual(params["element"], "foo=bar")
    }

    func testElementWithPlusIsEncodedCorrectly() throws {
        let path = try ScreenshotCommand.buildPath(from: ["--element", "a+b"])
        let params = queryParams(path)
        XCTAssertEqual(params["element"], "a+b")
    }

    // MARK: - Helpers

    /// Parse query params via URLComponents so tests verify decoded values,
    /// not raw percent-encoded strings.
    private func queryParams(_ path: String) -> [String: String] {
        guard let components = URLComponents(string: path) else { return [:] }
        var result: [String: String] = [:]
        for item in components.queryItems ?? [] {
            result[item.name] = item.value
        }
        return result
    }
}
