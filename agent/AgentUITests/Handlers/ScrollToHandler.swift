import Foundation
import XCTest

final class ScrollToHandler {
    private let appManager: AppManager

    init(appManager: AppManager) {
        self.appManager = appManager
    }

    func handle(_ request: HTTPRequest) -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let query = json["query"] as? String, !query.isEmpty else {
            return HTTPResponseBuilder.error("Missing 'query' field", code: "invalid_request")
        }

        let direction = json["direction"] as? String ?? "down"
        let maxSwipes = json["max_swipes"] as? Int ?? 10
        let settle = json["settle"] as? Double ?? 0.5

        guard maxSwipes > 0 else {
            return HTTPResponseBuilder.error(
                "max_swipes must be greater than 0",
                code: "invalid_request"
            )
        }

        guard ["up", "down", "left", "right"].contains(direction) else {
            return HTTPResponseBuilder.error(
                "Invalid direction: \(direction). Must be up, down, left, or right",
                code: "invalid_request"
            )
        }

        // An alias names a row in the list that was just read, so it is on screen
        // by construction — and the first swipe would invalidate it. "Scroll until
        // this already-visible thing appears" has no coherent answer, so it is
        // refused rather than silently resolved on the pre-check and never scrolled.
        if AliasResolver.isAlias(query) {
            return AliasResponse.unsupported("scroll-to", reason: .alreadyOnScreen)
        }

        let app = appManager.currentApp()

        // Check before any swipe — element may already be visible.
        if let found = DebugDescriptionParser.findElement(query: query, in: app) {
            return HTTPResponseBuilder.json([
                "found": true,
                "element": found.asDict,
                "swipes": 0,
                "direction": direction
            ])
        }

        for swipe in 1...maxSwipes {
            performSwipe(direction: direction, on: app)
            Thread.sleep(forTimeInterval: settle)

            if let found = DebugDescriptionParser.findElement(query: query, in: app) {
                return HTTPResponseBuilder.json([
                    "found": true,
                    "element": found.asDict,
                    "swipes": swipe,
                    "direction": direction
                ])
            }
        }

        return HTTPResponseBuilder.error(
            "Element not found after \(maxSwipes) swipes",
            code: "element_not_found",
            extra: [
                "swipes": maxSwipes,
                "direction": direction,
                "query": query
            ]
        )
    }

    /// Swipe gesture direction is opposite to scroll direction:
    /// "scroll down" (reveal content below) requires swipeUp (finger moves up).
    private func performSwipe(direction: String, on app: XCUIApplication) {
        switch direction {
        case "down":  app.swipeUp()
        case "up":    app.swipeDown()
        case "left":  app.swipeRight()
        case "right": app.swipeLeft()
        default:      break
        }
    }
}
