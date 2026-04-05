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
                guard let found = DebugDescriptionParser.findElement(query: query, in: app) else {
                    return HTTPResponseBuilder.error("Element not found: \(query)", code: "element_not_found")
                }
                let coord = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
                    .withOffset(CGVector(dx: found.centerX, dy: found.centerY))
                coord.tap()
                responseData["action_result"] = [
                    "type": found.type, "label": found.label, "identifier": found.identifier,
                    "frame": ["x": found.frame.x, "y": found.frame.y, "width": found.frame.w, "height": found.frame.h]
                ] as [String: Any]

            case "type":
                guard let text = json["text"] as? String else {
                    return HTTPResponseBuilder.error("Missing 'text' for type action", code: "invalid_request")
                }
                if let query = query {
                    guard let found = DebugDescriptionParser.findElement(query: query, in: app) else {
                        return HTTPResponseBuilder.error("Element not found: \(query)", code: "element_not_found")
                    }
                    let coord = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
                        .withOffset(CGVector(dx: found.centerX, dy: found.centerY))
                    coord.tap()
                }
                app.typeText(text)
                responseData["action_result"] = ["action": "type", "text": text]

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
                switch direction {
                case "up": target.swipeUp()
                case "down": target.swipeDown()
                case "left": target.swipeLeft()
                case "right": target.swipeRight()
                default:
                    return HTTPResponseBuilder.error("Invalid direction: \(direction)", code: "invalid_request")
                }
                responseData["action_result"] = ["action": "swipe", "direction": direction]

            case "tapcoord":
                guard let x = json["x"] as? Double, let y = json["y"] as? Double else {
                    return HTTPResponseBuilder.error("Missing 'x' or 'y' for tapcoord", code: "invalid_request")
                }
                let normalized = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
                let coord = normalized.withOffset(CGVector(dx: x, dy: y))
                coord.tap()
                responseData["action_result"] = ["action": "tapcoord", "x": x, "y": y]

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
            let pngData = screenshot.pngRepresentation
            do {
                try pngData.write(to: URL(fileURLWithPath: path))
                responseData["screenshot"] = ["file": path, "size": pngData.count]
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
