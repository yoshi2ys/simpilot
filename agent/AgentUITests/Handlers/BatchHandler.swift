import Foundation

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

            // Build query string from params
            var fullPath = path
            if let params = command["params"] as? [String: String], !params.isEmpty {
                let queryString = params.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
                fullPath += "?\(queryString)"
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
                queryParams: parseQueryParams(from: fullPath),
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

                if parsed["success"] as? Bool == false {
                    failed += 1
                    if stopOnError { stopped = true }
                } else {
                    completed += 1
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

        return HTTPResponseBuilder.json([
            "results": results,
            "total_commands": commands.count,
            "completed": completed,
            "failed": failed
        ])
    }

    private func parseQueryParams(from path: String) -> [String: String] {
        guard let queryStart = path.firstIndex(of: "?") else { return [:] }
        let queryString = String(path[path.index(after: queryStart)...])
        var params: [String: String] = [:]
        for pair in queryString.components(separatedBy: "&") {
            let parts = pair.components(separatedBy: "=")
            if parts.count == 2 {
                params[parts[0]] = parts[1].removingPercentEncoding ?? parts[1]
            }
        }
        return params
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
