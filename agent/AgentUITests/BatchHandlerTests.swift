import XCTest

/// Coverage for `BatchHandler.queryParams(from:)` (A16 fix) — the pure param
/// coercion function extracted so the query-string round-trip corruption bug
/// (values containing `=`/`&`, or non-string JSON scalars silently dropped)
/// can be exercised without an HTTP server.
final class BatchHandlerTests: XCTestCase {

    /// Decodes a full JSON command body and returns the raw `params` value
    /// exactly as `BatchHandler.handle` sees it via `command["params"]`.
    private func decodedParams(fromJSON json: String) -> Any? {
        let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        return obj?["params"]
    }

    private func expectSuccess(
        _ result: Result<[String: String], BatchParamError>,
        file: StaticString = #filePath, line: UInt = #line
    ) -> [String: String] {
        switch result {
        case .success(let params): return params
        case .failure(let failure):
            XCTFail("expected success, got failure: \(failure.code) \(failure.message)", file: file, line: line)
            return [:]
        }
    }

    private func expectFailure(
        _ result: Result<[String: String], BatchParamError>,
        file: StaticString = #filePath, line: UInt = #line
    ) -> BatchParamError {
        switch result {
        case .success(let params):
            XCTFail("expected failure, got success: \(params)", file: file, line: line)
            return BatchParamError(code: "", message: "")
        case .failure(let failure): return failure
        }
    }

    func test_queryParams_valueWithEqualsAndAmpersand_survivesWithoutRoundTrip() {
        let raw = decodedParams(fromJSON: #"{"params": {"q": "a=b&c=d"}}"#)
        let params = expectSuccess(BatchHandler.queryParams(from: raw))
        XCTAssertEqual(params["q"], "a=b&c=d")
    }

    func test_queryParams_intNumber_rendersWithoutDecimalPoint() {
        let raw = decodedParams(fromJSON: #"{"params": {"scale": 2}}"#)
        let params = expectSuccess(BatchHandler.queryParams(from: raw))
        XCTAssertEqual(params["scale"], "2")
    }

    func test_queryParams_doubleNumber_rendersWithDecimalPoint() {
        let raw = decodedParams(fromJSON: #"{"params": {"scale": 2.5}}"#)
        let params = expectSuccess(BatchHandler.queryParams(from: raw))
        XCTAssertEqual(params["scale"], "2.5")
    }

    func test_queryParams_boolTrue_rendersAsTrueString() {
        let raw = decodedParams(fromJSON: #"{"params": {"flag": true}}"#)
        let params = expectSuccess(BatchHandler.queryParams(from: raw))
        XCTAssertEqual(params["flag"], "true")
    }

    func test_queryParams_arrayValue_rejectsNamingOffendingKey() {
        let raw = decodedParams(fromJSON: #"{"params": {"bad": [1, 2]}}"#)
        let failure = expectFailure(BatchHandler.queryParams(from: raw))
        XCTAssertEqual(failure.code, "invalid_command")
        XCTAssertTrue(failure.message.contains("bad"))
    }

    func test_queryParams_nonDictParams_rejects() {
        let raw = decodedParams(fromJSON: #"{"params": "oops"}"#)
        let failure = expectFailure(BatchHandler.queryParams(from: raw))
        XCTAssertEqual(failure.code, "invalid_command")
    }

    func test_queryParams_missingParamsKey_succeedsEmpty() {
        let raw = decodedParams(fromJSON: "{}")
        let params = expectSuccess(BatchHandler.queryParams(from: raw))
        XCTAssertTrue(params.isEmpty)
    }

    /// `JSONSerialization` decodes JSON `null` to `NSNull()`, not Swift `nil`,
    /// so a `guard let` alone lets it reach the dictionary cast and reject it.
    /// Clients that serialize an unset optional (`json.dumps({"params": None})`,
    /// a Go struct without `omitempty`) send exactly this.
    func test_queryParams_explicitNull_meansNoParams() {
        let raw = decodedParams(fromJSON: #"{"params": null}"#)
        let params = expectSuccess(BatchHandler.queryParams(from: raw))
        XCTAssertTrue(params.isEmpty)
    }

    /// Handlers parse integer params with `Int(_:)`, and `Int("1.0")` is nil —
    /// so an integral float must render as an integer or the receiving filter is
    /// silently ignored while the response still says `success: true`.
    func test_queryParams_integralDouble_rendersAsInteger() {
        let raw = decodedParams(fromJSON: #"{"params": {"level": 1.0}}"#)
        let params = expectSuccess(BatchHandler.queryParams(from: raw))
        XCTAssertEqual(params["level"], "1")
        XCTAssertNotNil(Int(params["level"] ?? ""), "the receiving handler must be able to parse it")
    }

    func test_queryParams_fractionalDouble_keepsItsFraction() {
        let raw = decodedParams(fromJSON: #"{"params": {"scale": 0.5}}"#)
        let params = expectSuccess(BatchHandler.queryParams(from: raw))
        XCTAssertEqual(params["scale"], "0.5")
        XCTAssertEqual(Double(params["scale"] ?? ""), 0.5)
    }

    func test_queryParams_nullValueInsideParams_isRejected() {
        // A null *value* is different from a null params object: the caller
        // named a key and gave it nothing, which no handler can act on.
        let raw = decodedParams(fromJSON: #"{"params": {"level": null}}"#)
        let failure = expectFailure(BatchHandler.queryParams(from: raw))
        XCTAssertEqual(failure.code, "invalid_command")
        XCTAssertTrue(failure.message.contains("level"))
    }
}
