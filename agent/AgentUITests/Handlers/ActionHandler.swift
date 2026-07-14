import Foundation
import XCTest

final class ActionHandler {
    private let appManager: AppManager

    init(appManager: AppManager) {
        self.appManager = appManager
    }

    func handle(_ request: HTTPRequest) -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let action = json["action"] as? String else {
            return HTTPResponseBuilder.error("Missing 'action' field", code: "invalid_request")
        }

        let query = json["query"] as? String
        let screenshotPath = json["screenshot"] as? String
        let screenshotScaleRaw = json["screenshot_scale"]
        let screenshotElement = json["screenshot_element"] as? String
        let screenshotFormat = json["screenshot_format"] as? String ?? "png"
        guard screenshotFormat == "png" || screenshotFormat == "jpeg" else {
            return HTTPResponseBuilder.error(
                "Invalid screenshot_format '\(screenshotFormat)': must be 'png' or 'jpeg'",
                code: "invalid_request"
            )
        }
        let screenshotQuality = json["screenshot_quality"] as? Int ?? 80
        if screenshotFormat == "jpeg" && !(0...100).contains(screenshotQuality) {
            return HTTPResponseBuilder.error(
                "Invalid screenshot_quality \(screenshotQuality): must be 0-100",
                code: "invalid_request"
            )
        }
        let elementsLevel = json["elements_level"] as? Int
        let settleTimeout = json["settle_timeout"] as? Double ?? 1.0

        let app = appManager.currentApp()
        var responseData: [String: Any] = [:]

        // 1. Execute action. Every branch delegates to a shared resolver that
        // returns an envelope instead of throwing, so there is nothing to catch.
        switch action {
        case "tap":
            guard let query = query else {
                return HTTPResponseBuilder.error("Missing 'query' for tap action", code: "invalid_request")
            }
            let resolution = TapHandler.resolveAndTap(
                query: query,
                wait: TapHandler.parseWaitArgs(from: json),
                gesture: .tap,
                in: app
            )
            switch resolution {
            case .success(let element):
                responseData["action_result"] = element
            default:
                return TapHandler.responseData(from: resolution)
            }

        case "type":
            guard let text = json["text"] as? String else {
                return HTTPResponseBuilder.error("Missing 'text' for type action", code: "invalid_request")
            }
            let typeResolution = TypeHandler.resolveAndType(
                query: query,
                text: text,
                method: json["method"] as? String ?? "auto",
                wait: TapHandler.parseWaitArgs(from: json),
                in: app
            )
            switch typeResolution {
            case .success(let usedMethod, let element):
                var actionResult: [String: Any] = ["action": "type", "text": text, "method": usedMethod]
                if let element { actionResult["element"] = element }
                responseData["action_result"] = actionResult
            case .failure(let failure):
                return TypeHandler.failureResponse(for: failure)
            }

        case "swipe":
            guard let direction = json["direction"] as? String else {
                return HTTPResponseBuilder.error("Missing 'direction' for swipe action", code: "invalid_request")
            }
            let velocity = json["velocity"] as? String ?? "default"
            let swipeResolution = SwipeHandler.resolveAndSwipe(
                query: query,
                direction: direction,
                velocity: velocity,
                wait: TapHandler.parseWaitArgs(from: json),
                in: app
            )
            switch swipeResolution {
            case .success(let data):
                responseData["action_result"] = data
            default:
                return SwipeHandler.responseData(from: swipeResolution)
            }

        case "tapcoord":
            #if os(tvOS)
            return HTTPResponseBuilder.error("tapcoord is not supported on tvOS", code: "unsupported_platform")
            #else
            guard let x = json["x"] as? Double, let y = json["y"] as? Double else {
                return HTTPResponseBuilder.error("Missing 'x' or 'y' for tapcoord", code: "invalid_request")
            }
            let normalized = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            let coord = normalized.withOffset(CGVector(dx: x, dy: y))
            coord.tap()
            responseData["action_result"] = ["action": "tapcoord", "x": x, "y": y]
            #endif

        default:
            return HTTPResponseBuilder.error("Unknown action: \(action)", code: "invalid_request")
        }

        // 2. Wait for UI to settle
        Thread.sleep(forTimeInterval: settleTimeout)
        responseData["settled"] = true

        // 3. Screenshot (optional)
        if let path = screenshotPath, !path.isEmpty {
            let fullPng: Data?
            if let screenshotElement = screenshotElement {
                var resolved: XCUIElement?
                do {
                    resolved = try ElementResolver.resolve(query: screenshotElement, in: app)
                } catch {
                    responseData["screenshot"] = ["error": "Element not found: \(screenshotElement)", "code": "element_not_found"]
                }
                if let element = resolved {
                    var pngResult: Data?
                    let failure = catchObjCException {
                        pngResult = element.screenshot().pngRepresentation
                    }
                    if let failure {
                        responseData["screenshot"] = ["error": "Screenshot failed for element '\(screenshotElement)': \(failure)", "code": "screenshot_failed"]
                        fullPng = nil
                    } else {
                        fullPng = pngResult!
                    }
                } else {
                    fullPng = nil
                }
            } else {
                fullPng = XCUIScreen.main.screenshot().pngRepresentation
            }
            if let fullPng = fullPng {
                // Same scale rule as ScreenshotHandler: reject a bogus factor
                // instead of silently coercing to 1.0 (A23). Soft-fail here — a
                // bad scale annotates the screenshot slot, it doesn't fail the
                // whole action.
                let spec = ScreenshotHandler.scaleSpec(from: screenshotScaleRaw)
                if case .invalid = spec {
                    responseData["screenshot"] = [
                        "error": "Invalid screenshot scale; must be a positive number or 'native'",
                        "code": "invalid_request"
                    ]
                } else {
                    let pngData: Data
                    let scaleOut: Any
                    if case .factor(let scale) = spec {
                        pngData = ScreenshotScaler.scaled(pngData: fullPng, scale: scale) ?? fullPng
                        scaleOut = scale
                    } else {
                        pngData = fullPng
                        scaleOut = "native"
                    }
                    let outputData: Data
                    let outputFormat: String
                    if screenshotFormat == "jpeg" {
                        outputData = ScreenshotConverter.toJPEG(pngData: pngData, quality: screenshotQuality) ?? pngData
                        outputFormat = outputData == pngData ? "png" : "jpeg"
                    } else {
                        outputData = pngData
                        outputFormat = "png"
                    }
                    do {
                        try outputData.write(to: URL(fileURLWithPath: path))
                        responseData["screenshot"] = [
                            "file": path, "size": outputData.count,
                            "scale": scaleOut, "format": outputFormat
                        ]
                    } catch {
                        responseData["screenshot"] = ["error": "Failed to write: \(error.localizedDescription)"]
                    }
                }
            }
        }

        // 4. Elements (optional)
        if let level = elementsLevel {
            switch level {
            case 0:
                responseData["elements"] = DebugDescriptionParser.parseSummary(from: app)
            case 1:
                responseData["elements"] = DebugDescriptionParser.parseActionableList(from: app)
            case 2:
                responseData["elements"] = DebugDescriptionParser.parseCompactTree(from: app)
            default:
                responseData["elements"] = DebugDescriptionParser.parseTree(from: app)
            }
        }

        return HTTPResponseBuilder.json(responseData)
    }
}
