import Foundation

enum StepExecutor {

    /// Execute a single step action against the agent via HTTP.
    /// Returns the parsed JSON response dictionary, or throws on network/parse error.
    static func execute(
        _ action: StepAction,
        client: HTTPClient,
        config: ScenarioConfig
    ) throws -> [String: Any] {
        switch action {
        case .launch(let bundleId):
            return try postJSON(client, "/launch", ["bundleId": bundleId], config: config)

        case .terminate(let bundleId):
            return try postJSON(client, "/terminate", ["bundleId": bundleId], config: config)

        case .activate(let bundleId):
            return try postJSON(client, "/activate", ["bundleId": bundleId], config: config)

        case .tap(let query, let waitUntil, let timeout):
            var body: [String: Any] = ["query": query]
            if let waitUntil {
                let parts = waitUntil.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                body["wait_until"] = parts
            }
            if let timeout {
                body["timeout_ms"] = Int(timeout * 1000)
            }
            return try postJSON(client, "/tap", body, config: config, stepTimeout: timeout)

        case .type(let text, let into, let method):
            var body: [String: Any] = ["text": text]
            if let into { body["query"] = into }
            if let method { body["method"] = method }
            return try postJSON(client, "/type", body, config: config)

        case .swipe(let direction, let on, let velocity):
            var body: [String: Any] = ["direction": direction]
            if let on { body["query"] = on }
            if let velocity { body["velocity"] = velocity }
            return try postJSON(client, "/swipe", body, config: config)

        case .scrollTo(let query, let direction, let maxSwipes):
            var body: [String: Any] = ["query": query]
            if let direction { body["direction"] = direction }
            if let maxSwipes { body["max_swipes"] = maxSwipes }
            return try postJSON(client, "/scroll-to", body, config: config)

        case .longpress(let query, let duration):
            var body: [String: Any] = ["query": query]
            if let duration { body["duration"] = duration }
            return try postJSON(client, "/longpress", body, config: config)

        case .doubletap(let query):
            return try postJSON(client, "/doubletap", ["query": query], config: config)

        case .drag(let query, let to, let toX, let toY, let fromX, let fromY, let duration):
            var body: [String: Any] = [:]
            if let query { body["query"] = query }
            if let to { body["to_query"] = to }
            if let toX { body["to_x"] = toX }
            if let toY { body["to_y"] = toY }
            if let fromX { body["from_x"] = fromX }
            if let fromY { body["from_y"] = fromY }
            if let duration { body["duration"] = duration }
            return try postJSON(client, "/drag", body, config: config)

        case .pinch(let query, let scale, let velocity):
            var body: [String: Any] = ["scale": scale]
            if let query { body["query"] = query }
            if let velocity { body["velocity"] = velocity }
            return try postJSON(client, "/pinch", body, config: config)

        case .wait(let query, let timeout, let gone):
            var body: [String: Any] = ["query": query, "exists": !gone]
            // WaitHandler expects timeout in seconds (not ms), matching legacy API
            if let timeout { body["timeout"] = timeout }
            return try postJSON(client, "/wait", body, config: config, stepTimeout: timeout)

        case .assert(let predicate, let query, let expected, let timeout):
            var body: [String: Any] = [
                "predicate": predicate,
                "query": query,
            ]
            if let expected { body["expected"] = expected }
            let effectiveTimeout = timeout ?? config.timeout
            body["timeout_ms"] = Int(effectiveTimeout * 1000)
            return try postJSON(client, "/assert", body, config: config, stepTimeout: effectiveTimeout)

        case .screenshot(let file, let scale, let element, let format, let quality):
            return try getWithQuery(client, "/screenshot", config: config, params: [
                ("scale", scale), ("file", file), ("element", element),
                ("format", format), ("quality", quality.map(String.init)),
            ])

        case .elements(let level, let type, let contains):
            return try getWithQuery(client, "/elements", config: config, params: [
                ("level", level.map(String.init)), ("type", type), ("contains", contains),
            ])

        case .sleep(let seconds):
            Thread.sleep(forTimeInterval: seconds)
            return ["success": true, "data": ["slept": seconds]]
        }
    }

    // MARK: - HTTP Helpers

    /// POST with JSON body, return parsed response dictionary.
    private static func postJSON(
        _ client: HTTPClient, _ path: String, _ body: [String: Any],
        config: ScenarioConfig, stepTimeout: Double? = nil
    ) throws -> [String: Any] {
        let httpTimeout = computeHTTPTimeout(config: config, stepTimeout: stepTimeout)
        let data = try client.post(path, body: body, timeout: httpTimeout)
        return try parseResponse(data)
    }

    /// GET with optional query parameters.
    private static func getWithQuery(
        _ client: HTTPClient, _ basePath: String,
        config: ScenarioConfig, stepTimeout: Double? = nil,
        params: [(String, String?)] = []
    ) throws -> [String: Any] {
        var components = URLComponents()
        components.path = basePath
        let items = params.compactMap { (k, v) in v.map { URLQueryItem(name: k, value: $0) } }
        if !items.isEmpty { components.queryItems = items }
        let path = components.string ?? basePath
        let httpTimeout = computeHTTPTimeout(config: config, stepTimeout: stepTimeout)
        let data = try client.get(path, timeout: httpTimeout)
        return try parseResponse(data)
    }

    private static func computeHTTPTimeout(config: ScenarioConfig, stepTimeout: Double?) -> TimeInterval {
        let logical = max(config.timeout, stepTimeout ?? config.timeout)
        return logical + 5 // 5s buffer for network/processing
    }

    private static func parseResponse(_ data: Data) throws -> [String: Any] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let body = String(data: data, encoding: .utf8) ?? "<non-UTF-8 data>"
            throw NSError(domain: "simpilot", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "agent returned non-JSON response: \(body)"
            ])
        }
        return json
    }

    /// Check if a response JSON indicates success.
    static func isSuccess(_ response: [String: Any]) -> Bool {
        (response["success"] as? Bool) ?? true
    }

    /// Extract error message from a failure response.
    static func errorMessage(_ response: [String: Any]) -> String? {
        guard let error = response["error"] as? [String: Any] else { return nil }
        return (error["message"] as? String) ?? (error["code"] as? String)
    }
}
