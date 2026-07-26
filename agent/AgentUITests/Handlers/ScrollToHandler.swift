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

        // Both positional forms name something already on screen — an alias because
        // the list was just read, a row selector because only visible rows are
        // numbered — and the first swipe would invalidate either. "Scroll until this
        // already-visible thing appears" has no coherent answer, so it is refused
        // rather than silently resolved on the pre-check and never scrolled.
        if let refusal = PositionalQuery.refusal(
            for: query, command: "scroll-to", reason: .alreadyOnScreen
        ) {
            return refusal
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
            // The swipe just moved the content this loop is searching (SU5): the
            // check below has to read the screen, not the tree from before it.
            AXTree.settle(settle)

            if let found = DebugDescriptionParser.findElement(query: query, in: app) {
                return HTTPResponseBuilder.json([
                    "found": true,
                    "element": found.asDict,
                    "swipes": swipe,
                    "direction": direction
                ])
            }
        }

        return Self.notFound(query: query, direction: direction, maxSwipes: maxSwipes)
    }

    /// Exhausted the swipe budget without the element appearing.
    ///
    /// Static so the hint can be tested without a live app. It overrides the
    /// standard `element_not_found` hint, which tells the caller to reach for
    /// `scroll-to` — absurd advice from `scroll-to` itself.
    static func notFound(query: String, direction: String, maxSwipes: Int) -> Data {
        HTTPResponseBuilder.error(
            "Element not found after \(maxSwipes) swipes",
            code: "element_not_found",
            // The message and `extra` already report the direction and the swipe
            // count; repeating them here would be three statements of two facts.
            hint: "Try a larger `--max-swipes`, the opposite `--direction`, or check the label "
                + "with `elements --format outline`.",
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
