import Foundation

typealias HandlerFunc = (HTTPRequest) -> Data

final class Router {
    /// A registered endpoint and the one thing the router needs to know about it
    /// beyond how to run it: whether it can change what is on screen (SU5).
    private struct Route {
        let handler: HandlerFunc
        let mutates: Bool
    }

    private var routes: [String: Route] = [:]
    private let appManager = AppManager()
    /// Held only so `/info` can report the resolved port/bind rather than
    /// re-reading the environment. Authentication lives at the socket boundary
    /// in `HTTPServer`, not here.
    private let config: AgentConfig

    init(config: AgentConfig) {
        self.config = config
        registerRoutes()
    }

    /// Execute a handler directly without main-thread dispatch or duration injection.
    /// Used by BatchHandler to avoid deadlocks when calling sub-commands.
    func handleDirect(_ request: HTTPRequest) -> Data {
        let key = Self.key(method: request.method, path: request.path)
        guard let route = routes[key] else {
            return HTTPResponseBuilder.error("No route for \(key)", code: "not_found", status: 404)
        }
        return safeExecute(route.handler, request: request)
    }

    /// Whether running this endpoint can change what is on screen, so a tree
    /// fetched before it must not be reused after it (SU5).
    ///
    /// The answer lives on the registration rather than in a second table beside
    /// it: the routing table is the one place every endpoint is named exactly
    /// once, and `route(_:_:_:mutates:)` has no default, so a new endpoint does
    /// not compile until someone decides. An unregistered path answers `true` —
    /// `handleDirect` 404s it, but the safe direction has to be this one anyway.
    func changesScreen(method: String, path: String) -> Bool {
        routes[Self.key(method: method, path: path)]?.mutates ?? true
    }

    private static func key(method: String, path: String) -> String {
        "\(method) \(path)"
    }

    func handle(_ request: HTTPRequest) -> Data {
        let key = Self.key(method: request.method, path: request.path)
        guard let route = routes[key] else {
            return HTTPResponseBuilder.error(
                "No route for \(key)",
                code: "not_found",
                status: 404
            )
        }

        let start = CFAbsoluteTimeGetCurrent()
        var result: Data!
        DispatchQueue.main.sync {
            result = self.safeExecute(route.handler, request: request)
        }
        let durationMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        return injectDuration(into: result, durationMs: durationMs)
    }

    /// Wraps handler execution to catch both Swift errors and Objective-C NSExceptions.
    private func safeExecute(_ handler: HandlerFunc, request: HTTPRequest) -> Data {
        var result: Data?
        let exceptionMessage = catchObjCException {
            result = handler(request)
        }
        if let msg = exceptionMessage {
            print("[simpilot] Caught ObjC exception: \(msg)")
            return HTTPResponseBuilder.error(msg, code: "objc_exception", status: 500)
        }
        return result ?? HTTPResponseBuilder.error("Handler returned nil", code: "internal_error", status: 500)
    }

    private func injectDuration(into data: Data, durationMs: Double) -> Data {
        // The handler returns a full HTTP response (headers + JSON body).
        // Split at the blank line separating headers from body.
        guard let dataString = String(data: data, encoding: .utf8),
              let range = dataString.range(of: "\r\n\r\n") else {
            return data
        }

        let headers = dataString[dataString.startIndex..<range.lowerBound]
        let bodyString = dataString[range.upperBound...]

        guard let bodyData = bodyString.data(using: .utf8),
              var json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            return data
        }

        json["duration_ms"] = Int(durationMs)

        guard let updatedBody = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else {
            return data
        }

        // Rebuild with updated Content-Length
        var updatedHeaders = ""
        for line in headers.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("content-length:") {
                updatedHeaders += "Content-Length: \(updatedBody.count)\r\n"
            } else {
                updatedHeaders += line + "\r\n"
            }
        }
        updatedHeaders += "\r\n"

        var responseData = updatedHeaders.data(using: .utf8)!
        responseData.append(updatedBody)
        return responseData
    }

    private func registerRoutes() {
        let healthHandler = HealthHandler()
        let launchHandler = LaunchHandler(appManager: appManager)
        let terminateHandler = TerminateHandler(appManager: appManager)
        let activateHandler = ActivateHandler(appManager: appManager)
        let tapHandler = TapHandler(appManager: appManager)
        let tapCoordHandler = TapCoordHandler(appManager: appManager)
        let typeHandler = TypeHandler(appManager: appManager)
        let screenshotHandler = ScreenshotHandler(appManager: appManager)
        let elementsHandler = ElementsHandler(appManager: appManager)
        let sourceHandler = SourceHandler(appManager: appManager)
        let infoHandler = InfoHandler(config: config)
        let swipeHandler = SwipeHandler(appManager: appManager)
        let longPressHandler = LongPressHandler(appManager: appManager)
        let doubleTapHandler = DoubleTapHandler(appManager: appManager)
        let waitHandler = WaitHandler(appManager: appManager)
        let assertHandler = AssertHandler(appManager: appManager)
        let scrollToHandler = ScrollToHandler(appManager: appManager)
        let dragHandler = DragHandler(appManager: appManager)
        let pinchHandler = PinchHandler(appManager: appManager)
        let sliderHandler = SliderHandler(appManager: appManager)

        route("GET", "/health", healthHandler.handle, mutates: false)
        route("POST", "/launch", launchHandler.handle, mutates: true)
        route("POST", "/terminate", terminateHandler.handle, mutates: true)
        route("POST", "/activate", activateHandler.handle, mutates: true)
        route("POST", "/tap", tapHandler.handle, mutates: true)
        route("POST", "/tapcoord", tapCoordHandler.handle, mutates: true)
        route("POST", "/type", typeHandler.handle, mutates: true)
        route("GET", "/screenshot", screenshotHandler.handle, mutates: false)
        route("GET", "/elements", elementsHandler.handle, mutates: false)
        route("GET", "/source", sourceHandler.handle, mutates: false)
        route("GET", "/info", infoHandler.handle, mutates: false)
        route("POST", "/swipe", swipeHandler.handle, mutates: true)
        route("POST", "/longpress", longPressHandler.handle, mutates: true)
        route("POST", "/doubletap", doubleTapHandler.handle, mutates: true)
        route("POST", "/wait", waitHandler.handle, mutates: false)
        route("POST", "/assert", assertHandler.handle, mutates: false)
        route("POST", "/scroll-to", scrollToHandler.handle, mutates: true)
        route("POST", "/drag", dragHandler.handle, mutates: true)
        route("POST", "/pinch", pinchHandler.handle, mutates: true)
        route("POST", "/slider", sliderHandler.handle, mutates: true)

        let clipboardHandler = ClipboardHandler()
        route("GET", "/clipboard", clipboardHandler.handleGet, mutates: false)
        route("POST", "/clipboard", clipboardHandler.handleSet, mutates: true)

        let appearanceHandler = AppearanceHandler()
        route("GET", "/appearance", appearanceHandler.handleGet, mutates: false)
        route("POST", "/appearance", appearanceHandler.handleSet, mutates: true)

        let locationHandler = LocationHandler()
        route("POST", "/location", locationHandler.handle, mutates: true)

        let rotateHandler = RotateHandler()
        route("POST", "/rotate", rotateHandler.handle, mutates: true)

        let buttonHandler = ButtonHandler()
        route("POST", "/button", buttonHandler.handle, mutates: true)

        let alertHandler = AlertHandler()
        route("POST", "/alert", alertHandler.handle, mutates: true)

        let batchHandler = BatchHandler(router: self)
        let actionHandler = ActionHandler(appManager: appManager)
        route("POST", "/batch", batchHandler.handle, mutates: true)
        route("POST", "/action", actionHandler.handle, mutates: true)
    }

    /// `mutates` has no default on purpose: a new endpoint must not inherit an
    /// answer nobody chose. `true` is the safe side — it costs one tree fetch,
    /// where `false` on an endpoint that does move the UI would let the next
    /// sub-command in a `perBatch` batch pick a coordinate off the old screen.
    /// Endpoints that only change device state (`POST /clipboard`,
    /// `POST /location`) are `true` for that reason: the classification is about
    /// what the app may do in response, not about what the handler touches.
    private func route(
        _ method: String, _ path: String, _ handler: @escaping HandlerFunc, mutates: Bool
    ) {
        routes[Self.key(method: method, path: path)] = Route(handler: handler, mutates: mutates)
    }
}
