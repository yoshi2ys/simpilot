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
