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

    // MARK: - isNestedBatch (A35): a batch may not nest a batch

    func test_isNestedBatch_matchesOnlyThePostBatchRoute() {
        XCTAssertTrue(BatchHandler.isNestedBatch(method: "POST", path: "/batch"))
        // Everything else misses `handleDirect`'s exact `method + path` lookup and
        // 404s on its own — it is not the recursion vector. `GET /batch` included:
        // no such route exists, so calling it "nested batch" would misdiagnose it.
        let notNested = [("GET", "/batch"), ("POST", "/batch?foo=bar"),
                         ("POST", "/batchx"), ("POST", "/foo/batch"), ("POST", "/tap")]
        for (method, path) in notNested {
            XCTAssertFalse(BatchHandler.isNestedBatch(method: method, path: path), "wrongly flagged \(method) \(path)")
        }
    }

    // MARK: - failureResult (A35): one shape for a command that never ran

    func test_failureResult_hasTheStandardEnvelopeShape() {
        let result = BatchHandler.failureResult(code: "invalid_command", message: "nope", durationMs: 7)
        XCTAssertEqual(result["success"] as? Bool, false)
        XCTAssertTrue(result["data"] is NSNull)
        XCTAssertEqual(result["duration_ms"] as? Int, 7)
        let error = result["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? String, "invalid_command")
        XCTAssertEqual(error?["message"] as? String, "nope")
    }

    // MARK: - subCommandSucceeded (A34): only an explicit `true` is a success

    func test_subCommandSucceeded_explicitTrue() {
        XCTAssertTrue(BatchHandler.subCommandSucceeded(["success": true]))
    }

    func test_subCommandSucceeded_explicitFalse() {
        XCTAssertFalse(BatchHandler.subCommandSucceeded(["success": false]))
    }

    /// The counting rule that decides `failed`. A sub-envelope with no boolean
    /// `success` must not be counted as completed — that would let a batch that
    /// did not succeed report `success: true` and exit 0.
    func test_subCommandSucceeded_missingOrNonBooleanSuccessIsNotASuccess() {
        XCTAssertFalse(BatchHandler.subCommandSucceeded([:]))
        XCTAssertFalse(BatchHandler.subCommandSucceeded(["data": ["x": 1]]))
        XCTAssertFalse(BatchHandler.subCommandSucceeded(["success": "true"]))
        XCTAssertFalse(BatchHandler.subCommandSucceeded(["success": NSNull()]))
    }

    // MARK: - summarize (A34): sub-command failures must reach the exit code

    /// The status line and envelope body of an `HTTPResponseBuilder` response.
    private func envelope(of response: Data) throws -> (status: Int, json: [String: Any]) {
        let text = try XCTUnwrap(String(data: response, encoding: .utf8))
        let statusLine = try XCTUnwrap(text.components(separatedBy: "\r\n").first)
        let status = try XCTUnwrap(Int(statusLine.components(separatedBy: " ")[1]))
        let separator = try XCTUnwrap(text.range(of: "\r\n\r\n"))
        let body = Data(String(text[separator.upperBound...]).utf8)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        return (status, json)
    }

    private func okResult() -> [String: Any] {
        ["success": true, "data": NSNull(), "error": NSNull(), "duration_ms": 1]
    }

    /// Built through the production helper so a change to the sub-result shape
    /// can't leave the fixtures behind.
    private func failedResult() -> [String: Any] {
        BatchHandler.failureResult(code: "element_not_found", message: "no such element", durationMs: 1)
    }

    func test_summarize_allSucceeded_reportsSuccess() throws {
        let (status, json) = try envelope(
            of: BatchHandler.summarize(results: [okResult(), okResult()], completed: 2, failed: 0)
        )
        XCTAssertEqual(status, 200)
        XCTAssertEqual(json["success"] as? Bool, true)
        XCTAssertTrue(json["error"] is NSNull)
        let data = try XCTUnwrap(json["data"] as? [String: Any])
        XCTAssertEqual(data["failed"] as? Int, 0)
        XCTAssertEqual(data["skipped"] as? Int, 0)
        XCTAssertEqual(data["total_commands"] as? Int, 2)
    }

    /// A34. The outer envelope used to be `success: true` no matter how many
    /// sub-commands failed, so `simpilot batch` exited 0 and every script
    /// gating on `$?` missed the failure.
    ///
    /// The 200 matters: `HTTPResponseBuilder.error` defaults to 400, but the
    /// batch request itself was well-formed and ran.
    func test_summarize_anyFailure_reportsFailureAt200SoTheCLIExitsNonZero() throws {
        let (status, json) = try envelope(
            of: BatchHandler.summarize(results: [okResult(), failedResult()], completed: 1, failed: 1)
        )
        XCTAssertEqual(status, 200)
        XCTAssertEqual(json["success"] as? Bool, false)
        let error = try XCTUnwrap(json["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "batch_failed")
        XCTAssertEqual(error["message"] as? String, "1 of 2 commands failed")
    }

    /// Failing loudly must not cost the caller the per-command results: without
    /// them there is no way to learn *which* command failed.
    func test_summarize_failureStillCarriesEveryResult() throws {
        let (_, json) = try envelope(
            of: BatchHandler.summarize(results: [okResult(), failedResult()], completed: 1, failed: 1)
        )
        let data = try XCTUnwrap(json["data"] as? [String: Any])
        let results = try XCTUnwrap(data["results"] as? [[String: Any]])
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[1]["success"] as? Bool, false)
        XCTAssertEqual(data["completed"] as? Int, 1)
        XCTAssertEqual(data["failed"] as? Int, 1)
    }

    /// `stop_on_error` skips the tail. A skipped entry carries `success: false`
    /// too, so `summarize` must trust the caller's `failed` count rather than
    /// recount `results` — otherwise "1 of 3 failed" would read "3 of 3".
    ///
    /// `skipped` is reported explicitly so `completed + failed + skipped` adds up
    /// to `total_commands`; a caller filtering `results` on `success == false`
    /// would otherwise count 3 failures where the envelope claims 1.
    func test_summarize_reportsSkippedSeparatelyFromFailed() throws {
        let skipped = BatchHandler.failureResult(code: "skipped", message: "Skipped due to previous error")
        let (_, json) = try envelope(
            of: BatchHandler.summarize(results: [failedResult(), skipped, skipped], completed: 0, failed: 1)
        )
        XCTAssertEqual(json["success"] as? Bool, false)
        let error = try XCTUnwrap(json["error"] as? [String: Any])
        XCTAssertEqual(error["message"] as? String, "1 of 3 commands failed (2 skipped)")

        let data = try XCTUnwrap(json["data"] as? [String: Any])
        XCTAssertEqual(data["failed"] as? Int, 1)
        XCTAssertEqual(data["skipped"] as? Int, 2)
        XCTAssertEqual(data["completed"] as? Int, 0)
        XCTAssertEqual(data["total_commands"] as? Int, 3)
    }
}
