import Foundation

typealias HandlerFunc = (HTTPRequest) -> Data

final class Router {
    private var routes: [String: HandlerFunc] = [:]
    private let appManager = AppManager()

    init() {
        registerRoutes()
    }

    /// Execute a handler directly without main-thread dispatch or duration injection.
    /// Used by BatchHandler to avoid deadlocks when calling sub-commands.
    func handleDirect(_ request: HTTPRequest) -> Data {
        let key = "\(request.method) \(request.path)"
        guard let handler = routes[key] else {
            return HTTPResponseBuilder.error("No route for \(key)", code: "not_found", status: 404)
        }
        return safeExecute(handler, request: request)
    }

    func handle(_ request: HTTPRequest) -> Data {
        let key = "\(request.method) \(request.path)"
        guard let handler = routes[key] else {
            return HTTPResponseBuilder.error(
                "No route for \(key)",
                code: "not_found",
                status: 404
            )
        }

        let start = CFAbsoluteTimeGetCurrent()
        var result: Data!
        DispatchQueue.main.sync {
            result = self.safeExecute(handler, request: request)
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
        let screenshotHandler = ScreenshotHandler()
        let elementsHandler = ElementsHandler(appManager: appManager)
        let sourceHandler = SourceHandler(appManager: appManager)
        let infoHandler = InfoHandler()
        let swipeHandler = SwipeHandler(appManager: appManager)
        let longPressHandler = LongPressHandler(appManager: appManager)
        let doubleTapHandler = DoubleTapHandler(appManager: appManager)
        let waitHandler = WaitHandler(appManager: appManager)
        let assertHandler = AssertHandler(appManager: appManager)

        route("GET", "/health", healthHandler.handle)
        route("POST", "/launch", launchHandler.handle)
        route("POST", "/terminate", terminateHandler.handle)
        route("POST", "/activate", activateHandler.handle)
        route("POST", "/tap", tapHandler.handle)
        route("POST", "/tapcoord", tapCoordHandler.handle)
        route("POST", "/type", typeHandler.handle)
        route("GET", "/screenshot", screenshotHandler.handle)
        route("GET", "/elements", elementsHandler.handle)
        route("GET", "/source", sourceHandler.handle)
        route("GET", "/info", infoHandler.handle)
        route("POST", "/swipe", swipeHandler.handle)
        route("POST", "/longpress", longPressHandler.handle)
        route("POST", "/doubletap", doubleTapHandler.handle)
        route("POST", "/wait", waitHandler.handle)
        route("POST", "/assert", assertHandler.handle)

        let clipboardHandler = ClipboardHandler()
        route("GET", "/clipboard", clipboardHandler.handleGet)
        route("POST", "/clipboard", clipboardHandler.handleSet)

        let appearanceHandler = AppearanceHandler()
        route("GET", "/appearance", appearanceHandler.handleGet)
        route("POST", "/appearance", appearanceHandler.handleSet)

        let locationHandler = LocationHandler()
        route("POST", "/location", locationHandler.handle)

        let batchHandler = BatchHandler(router: self)
        let actionHandler = ActionHandler(appManager: appManager)
        route("POST", "/batch", batchHandler.handle)
        route("POST", "/action", actionHandler.handle)
    }

    private func route(_ method: String, _ path: String, _ handler: @escaping HandlerFunc) {
        routes["\(method) \(path)"] = handler
    }
}
