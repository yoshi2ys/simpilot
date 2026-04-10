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
        let elementsLevel = json["elements_level"] as? Int
        let settleTimeout = json["settle_timeout"] as? Double ?? 1.0

        let app = appManager.currentApp()
        var responseData: [String: Any] = [:]

        // 1. Execute action
        do {
            switch action {
            case "tap":
                guard let query = query else {
                    return HTTPResponseBuilder.error("Missing 'query' for tap action", code: "invalid_request")
                }
                #if !os(tvOS)
                if let found = DebugDescriptionParser.findElement(query: query, in: app) {
                    let coordTapFailed = catchObjCException {
                        let coord = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
                            .withOffset(CGVector(dx: found.centerX, dy: found.centerY))
                        coord.tap()
                    }
                    if coordTapFailed == nil {
                        responseData["action_result"] = [
                            "type": found.type, "label": found.label, "identifier": found.identifier,
                            "frame": ["x": found.frame.x, "y": found.frame.y, "width": found.frame.w, "height": found.frame.h]
                        ] as [String: Any]
                    } else {
                        let element = try ElementResolver.resolve(query: query, in: app)
                        element.tap()
                        responseData["action_result"] = ElementResolver.describe(element)
                    }
                } else {
                    return HTTPResponseBuilder.error("Element not found: \(query)", code: "element_not_found")
                }
                #else
                let element = try ElementResolver.resolve(query: query, in: app)
                XCUIRemote.shared.press(.select)
                responseData["action_result"] = ElementResolver.describe(element)
                #endif

            case "type":
                guard let text = json["text"] as? String else {
                    return HTTPResponseBuilder.error("Missing 'text' for type action", code: "invalid_request")
                }
                let method = json["method"] as? String ?? "auto"
                #if !os(tvOS)
                var targetCoord: XCUICoordinate?
                #endif
                if let query = query {
                    #if !os(tvOS)
                    if let found = DebugDescriptionParser.findElement(query: query, in: app) {
                        let coord = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
                            .withOffset(CGVector(dx: found.centerX, dy: found.centerY))
                        targetCoord = coord
                        let coordTapFailed = catchObjCException { coord.tap() }
                        if coordTapFailed != nil {
                            let tapElement = try ElementResolver.resolve(query: query, in: app)
                            tapElement.tap()
                        }
                    } else {
                        return HTTPResponseBuilder.error("Element not found: \(query)", code: "element_not_found")
                    }
                    #else
                    let _ = try ElementResolver.resolve(query: query, in: app)
                    XCUIRemote.shared.press(.select)
                    #endif
                }
                #if os(tvOS)
                let (usedMethod, inputError) = PasteHelper.performTextInput(text, method: method, at: nil, in: app)
                #else
                let (usedMethod, inputError) = PasteHelper.performTextInput(text, method: method, at: targetCoord, in: app)
                #endif
                if let inputError { return inputError }
                responseData["action_result"] = ["action": "type", "text": text, "method": usedMethod] as [String: Any]

            case "swipe":
                guard let direction = json["direction"] as? String else {
                    return HTTPResponseBuilder.error("Missing 'direction' for swipe action", code: "invalid_request")
                }
                let target: XCUIElement
                if let query = query {
                    // Swipe needs an XCUIElement (can't swipe by coordinate)
                    target = try ElementResolver.resolve(query: query, in: app)
                } else {
                    target = app
                }
                #if os(tvOS)
                switch direction {
                case "up": XCUIRemote.shared.press(.up)
                case "down": XCUIRemote.shared.press(.down)
                case "left": XCUIRemote.shared.press(.left)
                case "right": XCUIRemote.shared.press(.right)
                default:
                    return HTTPResponseBuilder.error("Invalid direction: \(direction)", code: "invalid_request")
                }
                #else
                switch direction {
                case "up": target.swipeUp()
                case "down": target.swipeDown()
                case "left": target.swipeLeft()
                case "right": target.swipeRight()
                default:
                    return HTTPResponseBuilder.error("Invalid direction: \(direction)", code: "invalid_request")
                }
                #endif
                responseData["action_result"] = ["action": "swipe", "direction": direction]

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
        } catch {
            return HTTPResponseBuilder.error(error.localizedDescription, code: "action_failed")
        }

        // 2. Wait for UI to settle
        Thread.sleep(forTimeInterval: settleTimeout)
        responseData["settled"] = true

        // 3. Screenshot (optional)
        if let path = screenshotPath, !path.isEmpty {
            let screenshot = XCUIScreen.main.screenshot()
            let fullPng = screenshot.pngRepresentation
            let pngData: Data
            let scaleOut: Any
            if let str = screenshotScaleRaw as? String, str == "native" {
                pngData = fullPng
                scaleOut = "native"
            } else {
                let scale = (screenshotScaleRaw as? Double) ?? 1.0
                pngData = ScreenshotScaler.scaled(pngData: fullPng, scale: scale) ?? fullPng
                scaleOut = scale
            }
            do {
                try pngData.write(to: URL(fileURLWithPath: path))
                responseData["screenshot"] = ["file": path, "size": pngData.count, "scale": scaleOut]
            } catch {
                responseData["screenshot"] = ["error": "Failed to write: \(error.localizedDescription)"]
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
