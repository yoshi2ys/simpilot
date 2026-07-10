import Foundation

/// Rejection reason for a malformed `command["params"]` value (A16).
struct BatchParamError: Error {
    let code: String
    let message: String
}

final class BatchHandler {
    private let router: Router

    init(router: Router) {
        self.router = router
    }

    func handle(_ request: HTTPRequest) -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let commands = json["commands"] as? [[String: Any]] else {
            return HTTPResponseBuilder.error("Missing or invalid 'commands' array", code: "invalid_request")
        }

        let stopOnError = json["stop_on_error"] as? Bool ?? false
        var results: [[String: Any]] = []
        var completed = 0
        var failed = 0
        var stopped = false

        for command in commands {
            if stopped {
                results.append(["success": false, "data": NSNull(),
                              "error": ["code": "skipped", "message": "Skipped due to previous error"],
                              "duration_ms": 0])
                continue
            }

            guard let method = command["method"] as? String,
                  let path = command["path"] as? String else {
                let errResult: [String: Any] = ["success": false, "data": NSNull(),
                    "error": ["code": "invalid_command", "message": "Missing method or path"],
                    "duration_ms": 0]
                results.append(errResult)
                failed += 1
                if stopOnError { stopped = true }
                continue
            }

            let subQueryParams: [String: String]
            switch Self.queryParams(from: command["params"]) {
            case .success(let params):
                subQueryParams = params
            case .failure(let failure):
                let errResult: [String: Any] = ["success": false, "data": NSNull(),
                    "error": ["code": failure.code, "message": failure.message],
                    "duration_ms": 0]
                results.append(errResult)
                failed += 1
                if stopOnError { stopped = true }
                continue
            }

            // Build body data
            var bodyData = Data()
            if let body = command["body"] as? [String: Any] {
                bodyData = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
            }

            // Create synthetic HTTPRequest
            let subRequest = HTTPRequest(
                method: method,
                path: path,
                queryParams: subQueryParams,
                headers: request.headers,
                body: bodyData
            )

            let start = CFAbsoluteTimeGetCurrent()
            let responseData = router.handleDirect(subRequest)
            let durationMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)

            // Parse the HTTP response to extract JSON body
            if let parsed = extractJSON(from: responseData) {
                var result = parsed
                result["duration_ms"] = durationMs
                results.append(result)

                if Self.subCommandSucceeded(parsed) {
                    completed += 1
                } else {
                    failed += 1
                    if stopOnError { stopped = true }
                }
            } else {
                let errResult: [String: Any] = ["success": false, "data": NSNull(),
                    "error": ["code": "parse_error", "message": "Failed to parse sub-command response"],
                    "duration_ms": durationMs]
                results.append(errResult)
                failed += 1
                if stopOnError { stopped = true }
            }
        }

        return Self.summarize(results: results, completed: completed, failed: failed)
    }

    /// Whether a sub-command's envelope reports success.
    ///
    /// Only an explicit `true` counts. Testing `success == false` instead would
    /// send an envelope whose `success` is missing or non-boolean down the
    /// *completed* path, so a batch that did not succeed would report
    /// `success: true` — the opposite of the CLI's `classify`, which calls such
    /// a body malformed. Static so `handle`'s counting rule is testable without
    /// a live `Router`.
    static func subCommandSucceeded(_ parsed: [String: Any]) -> Bool {
        parsed["success"] as? Bool == true
    }

    /// The batch envelope. `success` mirrors `simpilot run`'s report: false when
    /// any sub-command failed, so the CLI exits non-zero instead of reporting a
    /// clean run over a batch that tapped nothing.
    ///
    /// `completed` and `failed` come from the caller rather than being recounted
    /// here: a `stop_on_error` skip also carries `success: false`, so recounting
    /// `results` would report every skipped command as a failure. `skipped` is
    /// reported explicitly for the same reason — a caller who filters `results`
    /// on `success == false` would otherwise disagree with `failed`.
    /// `results.count` *is* the command count: every branch of `handle` appends
    /// exactly one entry.
    static func summarize(results: [[String: Any]], completed: Int, failed: Int) -> Data {
        let skipped = results.count - completed - failed
        let data: [String: Any] = [
            "results": results,
            "total_commands": results.count,
            "completed": completed,
            "failed": failed,
            "skipped": skipped
        ]
        guard failed > 0 else { return HTTPResponseBuilder.json(data) }

        let skippedNote = skipped > 0 ? " (\(skipped) skipped)" : ""
        return HTTPResponseBuilder.error(
            "\(failed) of \(results.count) commands failed\(skippedNote)",
            code: "batch_failed",
            // 200, not the default 400: the batch request itself was well-formed
            // and ran. Only some of the commands inside it failed.
            status: 200,
            data: data
        )
    }

    /// Coerces a decoded `command["params"]` value into query params without
    /// a string round-trip, so `=`/`&` inside a value can't corrupt it (A16).
    /// An absent key — or an explicit JSON `null`, which clients emit for an
    /// unset optional — means no params. A present non-dictionary, or a
    /// dictionary value that isn't a string/number/bool, is rejected loudly
    /// rather than silently dropped.
    static func queryParams(from raw: Any?) -> Result<[String: String], BatchParamError> {
        // JSONSerialization decodes `null` to NSNull(), not Swift nil, so
        // `guard let` alone would let it fall through to the dictionary cast
        // and reject a perfectly valid `"params": null`.
        guard let raw, !(raw is NSNull) else { return .success([:]) }
        guard let dict = raw as? [String: Any] else {
            return .failure(BatchParamError(code: "invalid_command", message: "'params' must be an object"))
        }
        var result: [String: String] = [:]
        for (key, value) in dict {
            switch value {
            case let string as String:
                result[key] = string
            case let number as NSNumber:
                result[key] = queryValue(for: number)
            default:
                return .failure(BatchParamError(code: "invalid_command", message: "params.\(key) must be a string, number, or boolean"))
            }
        }
        return .success(result)
    }

    /// Render a JSON number the way the receiving handler will parse it.
    ///
    /// Handlers read integer params with `Int(_:)`, which returns nil for
    /// `"1.0"` — so a client (or an LLM) writing `{"level": 1.0}` would have its
    /// filter silently ignored. Any float with no fractional part is therefore
    /// rendered as an integer; `Double("1")` still parses for the genuinely
    /// fractional params.
    private static func queryValue(for number: NSNumber) -> String {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }
        if CFNumberIsFloatType(number) {
            let value = number.doubleValue
            guard value == value.rounded(), let exact = Int64(exactly: value) else {
                return String(value)
            }
            return String(exact)
        }
        return String(number.int64Value)
    }

    private func extractJSON(from httpResponse: Data) -> [String: Any]? {
        guard let str = String(data: httpResponse, encoding: .utf8),
              let range = str.range(of: "\r\n\r\n") else { return nil }
        let bodyString = String(str[range.upperBound...])
        guard let bodyData = bodyString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else { return nil }
        return json
    }
}
