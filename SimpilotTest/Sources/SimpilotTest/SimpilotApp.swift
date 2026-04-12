import Foundation

/// Primary interaction surface for controlling an iOS app via the simpilot agent.
public struct SimpilotApp: Sendable {
    let client: HTTPClient

    init(client: HTTPClient) {
        self.client = client
    }

    // MARK: - Lifecycle

    /// Launch an app by bundle identifier.
    public func launch(_ bundleId: String) async throws {
        try await post("/launch", ["bundleId": bundleId])
    }

    /// Terminate an app by bundle identifier.
    public func terminate(_ bundleId: String) async throws {
        try await post("/terminate", ["bundleId": bundleId])
    }

    /// Activate (bring to foreground) an app by bundle identifier.
    public func activate(_ bundleId: String) async throws {
        try await post("/activate", ["bundleId": bundleId])
    }

    // MARK: - Tap

    /// Tap an element matching the query.
    public func tap(_ query: String, waitUntil: String? = nil, timeout: TimeInterval? = nil) async throws {
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
        try await post("/tap", body, timeout: timeout.map { $0 + 5 })
    }

    /// Double-tap an element matching the query.
    public func doubleTap(_ query: String) async throws {
        try await post("/doubletap", ["query": query])
    }

    /// Long-press an element matching the query.
    public func longPress(_ query: String, duration: TimeInterval? = nil) async throws {
        var body: [String: Any] = ["query": query]
        if let duration { body["duration"] = duration }
        try await post("/longpress", body)
    }

    /// Tap at absolute screen coordinates.
    public func tapCoordinate(x: Double, y: Double) async throws {
        try await post("/tapcoord", ["x": x, "y": y])
    }

    // MARK: - Type

    /// Type text into an element matching the query.
    public func type(_ text: String, into query: String, method: String? = nil) async throws {
        var body: [String: Any] = ["text": text, "query": query]
        if let method { body["method"] = method }
        try await post("/type", body)
    }

    /// Type text without targeting a specific element.
    public func type(_ text: String, method: String? = nil) async throws {
        var body: [String: Any] = ["text": text]
        if let method { body["method"] = method }
        try await post("/type", body)
    }

    // MARK: - Swipe & Scroll

    /// Swipe in a direction, optionally on a specific element.
    public func swipe(_ direction: String, on query: String? = nil, velocity: String? = nil) async throws {
        var body: [String: Any] = ["direction": direction]
        if let query { body["query"] = query }
        if let velocity { body["velocity"] = velocity }
        try await post("/swipe", body)
    }

    /// Scroll to find an element matching the query.
    public func scrollTo(_ query: String, direction: String? = nil, maxSwipes: Int? = nil) async throws {
        var body: [String: Any] = ["query": query]
        if let direction { body["direction"] = direction }
        if let maxSwipes { body["max_swipes"] = maxSwipes }
        try await post("/scroll-to", body)
    }

    // MARK: - Drag

    /// Drag from one element to another.
    public func drag(from query: String, to toQuery: String, duration: TimeInterval? = nil) async throws {
        var body: [String: Any] = ["query": query, "to_query": toQuery]
        if let duration { body["duration"] = duration }
        try await post("/drag", body)
    }

    /// Drag from an element to absolute coordinates.
    public func drag(from query: String, toX: Double, toY: Double, duration: TimeInterval? = nil) async throws {
        var body: [String: Any] = ["query": query, "to_x": toX, "to_y": toY]
        if let duration { body["duration"] = duration }
        try await post("/drag", body)
    }

    /// Drag from absolute coordinates to absolute coordinates.
    public func drag(fromX: Double, fromY: Double, toX: Double, toY: Double, duration: TimeInterval? = nil) async throws {
        var body: [String: Any] = ["from_x": fromX, "from_y": fromY, "to_x": toX, "to_y": toY]
        if let duration { body["duration"] = duration }
        try await post("/drag", body)
    }

    // MARK: - Pinch & Slider

    /// Pinch to zoom on an optional element. scale > 1 = zoom in, < 1 = zoom out.
    public func pinch(_ query: String? = nil, scale: Double, velocity: String? = nil) async throws {
        var body: [String: Any] = ["scale": scale]
        if let query { body["query"] = query }
        if let velocity { body["velocity"] = velocity }
        try await post("/pinch", body)
    }

    /// Adjust a slider to a normalized value (0.0–1.0).
    public func slider(_ query: String? = nil, value: Double) async throws {
        var body: [String: Any] = ["value": value]
        if let query { body["query"] = query }
        try await post("/slider", body)
    }

    // MARK: - Assertions

    /// Assert that an element matching the query exists.
    public func assertExists(_ query: String, timeout: TimeInterval? = nil) async throws {
        try await assertPredicate("exists", query: query, timeout: timeout)
    }

    /// Assert that an element matching the query does not exist.
    public func assertNotExists(_ query: String, timeout: TimeInterval? = nil) async throws {
        try await assertPredicate("not-exists", query: query, timeout: timeout)
    }

    /// Assert that an element's value matches the expected string.
    public func assertValue(_ query: String, expected: String, timeout: TimeInterval? = nil) async throws {
        try await assertPredicate("value", query: query, expected: expected, timeout: timeout)
    }

    /// Assert that an element is enabled.
    public func assertEnabled(_ query: String, timeout: TimeInterval? = nil) async throws {
        try await assertPredicate("enabled", query: query, timeout: timeout)
    }

    /// Assert that an element's label matches the expected string.
    public func assertLabel(_ query: String, expected: String, timeout: TimeInterval? = nil) async throws {
        try await assertPredicate("label", query: query, expected: expected, timeout: timeout)
    }

    /// Assert that an element is hittable.
    public func assertHittable(_ query: String, timeout: TimeInterval? = nil) async throws {
        try await assertPredicate("hittable", query: query, timeout: timeout)
    }

    private func assertPredicate(
        _ predicate: String, query: String,
        expected: String? = nil, timeout: TimeInterval? = nil
    ) async throws {
        var body: [String: Any] = ["predicate": predicate, "query": query]
        if let expected { body["expected"] = expected }
        if let timeout { body["timeout_ms"] = Int(timeout * 1000) }
        let httpTimeout = timeout.map { $0 + 5 }
        try await post("/assert", body, timeout: httpTimeout)
    }

    // MARK: - Wait

    /// Wait for an element to appear.
    public func waitFor(_ query: String, timeout: TimeInterval? = nil) async throws {
        var body: [String: Any] = ["query": query, "exists": true]
        if let timeout { body["timeout"] = timeout }
        try await post("/wait", body, timeout: timeout.map { $0 + 5 })
    }

    /// Wait for an element to disappear.
    public func waitForGone(_ query: String, timeout: TimeInterval? = nil) async throws {
        var body: [String: Any] = ["query": query, "exists": false]
        if let timeout { body["timeout"] = timeout }
        try await post("/wait", body, timeout: timeout.map { $0 + 5 })
    }

    // MARK: - Screenshot

    /// Take a screenshot. Returns the screenshot data.
    public func screenshot(
        file: String? = nil, scale: String? = nil,
        element: String? = nil, format: String? = nil,
        quality: Int? = nil
    ) async throws -> SimpilotScreenshot {
        let json = try await get("/screenshot", params: [
            ("file", file), ("scale", scale), ("element", element),
            ("format", format), ("quality", quality.map(String.init)),
        ])
        let data = json["data"]
        var imageData: Data?
        var filePath: String?
        if let dataDict = data as? [String: Any] {
            if let base64 = dataDict["base64"] as? String {
                imageData = Data(base64Encoded: base64)
            }
            filePath = dataDict["file"] as? String
        }
        return SimpilotScreenshot(
            data: imageData,
            format: format ?? "png",
            filePath: filePath
        )
    }

    // MARK: - Elements

    /// Query visible elements with optional filters.
    public func elements(
        level: Int? = nil, type: String? = nil,
        contains: String? = nil
    ) async throws -> [[String: Any]] {
        let json = try await get("/elements", params: [
            ("level", level.map(String.init)),
            ("type", type),
            ("contains", contains),
        ])
        if let data = json["data"] as? [[String: Any]] {
            return data
        }
        return []
    }

    /// Get the app's accessibility source tree.
    public func source() async throws -> [String: Any] {
        try await get("/source")
    }

    /// Get agent info.
    public func info() async throws -> [String: Any] {
        try await get("/info")
    }

    // MARK: - Alert

    /// Accept or dismiss a system alert.
    public func alert(_ action: String, timeout: TimeInterval? = nil) async throws {
        var body: [String: Any] = ["action": action]
        if let timeout { body["timeout"] = timeout }
        try await post("/alert", body)
    }

    // MARK: - Rotation

    /// Set device orientation (portrait, landscapeLeft, landscapeRight, portraitUpsideDown).
    public func rotate(_ orientation: String) async throws {
        try await post("/rotate", ["orientation": orientation])
    }

    // MARK: - Clipboard

    /// Read the device clipboard text.
    public func clipboard() async throws -> String {
        let json = try await get("/clipboard")
        if let data = json["data"] as? [String: Any],
           let text = data["text"] as? String {
            return text
        }
        return ""
    }

    /// Set the device clipboard text.
    public func setClipboard(_ text: String) async throws {
        try await post("/clipboard", ["text": text])
    }

    // MARK: - Appearance

    /// Get the current appearance mode (light, dark, unspecified).
    public func appearance() async throws -> String {
        let json = try await get("/appearance")
        if let data = json["data"] as? [String: Any],
           let mode = data["appearance"] as? String {
            return mode
        }
        return "unspecified"
    }

    /// Set appearance mode (light, dark, unspecified).
    public func setAppearance(_ mode: String) async throws {
        try await post("/appearance", ["mode": mode])
    }

    // MARK: - Location

    /// Set simulated device location.
    public func setLocation(latitude: Double, longitude: Double) async throws {
        try await post("/location", ["latitude": latitude, "longitude": longitude])
    }

    // MARK: - Health

    /// Check agent health. Throws if unreachable.
    public func health() async throws {
        _ = try await get("/health")
    }

    // MARK: - Element Query (chainable)

    /// Create a chainable element reference.
    public func element(_ query: String) -> SimpilotElement {
        SimpilotElement(query: query, app: self)
    }

    // MARK: - Internal HTTP helpers

    @discardableResult
    func post(_ path: String, _ body: [String: Any], timeout: TimeInterval? = nil) async throws -> [String: Any] {
        let data = try await client.post(path, body: body, timeout: timeout)
        let json = try Response.parse(data)
        try Response.requireSuccess(json)
        return json
    }

    func get(_ path: String, params: [(String, String?)] = [], timeout: TimeInterval? = nil) async throws -> [String: Any] {
        var components = URLComponents()
        components.path = path
        let items = params.compactMap { (k, v) in v.map { URLQueryItem(name: k, value: $0) } }
        if !items.isEmpty { components.queryItems = items }
        let fullPath = components.string ?? path
        let data = try await client.get(fullPath, timeout: timeout)
        let json = try Response.parse(data)
        try Response.requireSuccess(json)
        return json
    }
}

/// Screenshot result.
public struct SimpilotScreenshot: Sendable {
    /// Raw image data (nil if only saved to file).
    public let data: Data?
    /// Image format: "png" or "jpeg".
    public let format: String
    /// File path if the screenshot was saved to disk.
    public let filePath: String?
}
