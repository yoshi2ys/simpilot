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
            var components = URLComponents()
            components.path = "/screenshot"
            var items: [URLQueryItem] = []
            if let scale { items.append(URLQueryItem(name: "scale", value: scale)) }
            if let file { items.append(URLQueryItem(name: "file", value: file)) }
            if let element { items.append(URLQueryItem(name: "element", value: element)) }
            if let format { items.append(URLQueryItem(name: "format", value: format)) }
            if let quality { items.append(URLQueryItem(name: "quality", value: "\(quality)")) }
            if !items.isEmpty { components.queryItems = items }
            let path = components.string ?? "/screenshot"
            return try getJSON(client, path, config: config)

        case .elements(let level, let type, let contains):
            var components = URLComponents()
            components.path = "/elements"
            var items: [URLQueryItem] = []
            if let level { items.append(URLQueryItem(name: "level", value: "\(level)")) }
            if let type { items.append(URLQueryItem(name: "type", value: type)) }
            if let contains { items.append(URLQueryItem(name: "contains", value: contains)) }
            if !items.isEmpty { components.queryItems = items }
            let path = components.string ?? "/elements"
            return try getJSON(client, path, config: config)

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

    /// GET, return parsed response dictionary.
    private static func getJSON(
        _ client: HTTPClient, _ path: String,
        config: ScenarioConfig, stepTimeout: Double? = nil
    ) throws -> [String: Any] {
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
            if let str = String(data: data, encoding: .utf8) {
                return ["success": true, "data": str]
            }
            return ["success": true, "data": NSNull()]
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
