import Foundation
import XCTest

final class SwipeHandler: @unchecked Sendable {
    private let appManager: AppManager

    init(appManager: AppManager) {
        self.appManager = appManager
    }

    func handle(_ request: HTTPRequest) -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let direction = json["direction"] as? String else {
            return HTTPResponseBuilder.error(
                "Missing or invalid 'direction' in request body",
                code: "invalid_request"
            )
        }

        let query = json["query"] as? String
        let velocity = json["velocity"] as? String ?? "default"

        do {
            let app = appManager.currentApp()
            let target: XCUIElement
            if let query = query, !query.isEmpty {
                target = try ElementResolver.resolve(query: query, in: app)
            } else {
                target = app
            }

            #if os(tvOS)
            switch direction.lowercased() {
            case "up":
                XCUIRemote.shared.press(.up)
            case "down":
                XCUIRemote.shared.press(.down)
            case "left":
                XCUIRemote.shared.press(.left)
            case "right":
                XCUIRemote.shared.press(.right)
            default:
                return HTTPResponseBuilder.error(
                    "Invalid direction: \(direction). Use up, down, left, or right.",
                    code: "invalid_direction"
                )
            }
            #else
            let swipeVelocity: XCUIGestureVelocity
            switch velocity {
            case "slow": swipeVelocity = .slow
            case "fast": swipeVelocity = .fast
            default: swipeVelocity = .default
            }

            switch direction.lowercased() {
            case "up":
                target.swipeUp(velocity: swipeVelocity)
            case "down":
                target.swipeDown(velocity: swipeVelocity)
            case "left":
                target.swipeLeft(velocity: swipeVelocity)
            case "right":
                target.swipeRight(velocity: swipeVelocity)
            default:
                return HTTPResponseBuilder.error(
                    "Invalid direction: \(direction). Use up, down, left, or right.",
                    code: "invalid_direction"
                )
            }
            #endif

            var responseData: [String: Any] = [
                "direction": direction,
                "velocity": velocity,
                "action": "swipe"
            ]
            if let query = query {
                responseData["query"] = query
            }
            return HTTPResponseBuilder.json(responseData)
        } catch ElementResolverError.elementNotFound(let msg) {
            return HTTPResponseBuilder.error(msg, code: "element_not_found")
        } catch ElementResolverError.invalidQuery(let msg) {
            return HTTPResponseBuilder.error(msg, code: "invalid_query")
        } catch {
            return HTTPResponseBuilder.error(error.localizedDescription, code: "swipe_failed", status: 500)
        }
    }
}
