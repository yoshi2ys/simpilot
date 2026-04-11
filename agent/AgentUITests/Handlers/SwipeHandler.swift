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
        let app = appManager.currentApp()
        let resolution = Self.resolveAndSwipe(
            query: query,
            direction: direction,
            velocity: velocity,
            wait: TapHandler.parseWaitArgs(from: json),
            in: app
        )
        return Self.responseData(from: resolution)
    }

    // MARK: - Shared path

    enum Resolution {
        case success(responseData: [String: Any])
        case elementNotFound(message: String)
        case invalidQuery(message: String)
        case invalidDirection(direction: String)
        case waitTimeout(
            query: String,
            failedPredicates: [String],
            lastState: [String: Any]?,
            timeoutMs: Int
        )
        case failed(message: String)
    }

    /// Resolve `query` (or use the app itself when nil/empty), optionally
    /// gated by `wait`, then perform the swipe.
    ///
    /// Wait semantics: when `query` is present and `wait` has constraints,
    /// run `TapHandler.awaitPredicates` to block until the element satisfies
    /// the predicates. The polled `FoundElement` is discarded — swipe needs
    /// an `XCUIElement` (XCUITest has no coordinate-based swipe API), so the
    /// actual swipe target is re-resolved via `ElementResolver` after the
    /// gate clears. When `query` is nil/empty the swipe targets the whole
    /// app and wait is skipped (no element to poll).
    static func resolveAndSwipe(
        query: String?,
        direction: String,
        velocity: String,
        wait: TapHandler.WaitArgs,
        in app: XCUIApplication
    ) -> Resolution {
        if let query = query, !query.isEmpty {
            switch TapHandler.awaitPredicates(query: query, wait: wait, in: app) {
            case .notNeeded, .satisfied:
                break
            case .timedOut(let lastState, let failed):
                return .waitTimeout(
                    query: query,
                    failedPredicates: failed,
                    lastState: lastState,
                    timeoutMs: wait.timeoutMs
                )
            }
        }

        do {
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
                return .invalidDirection(direction: direction)
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
                return .invalidDirection(direction: direction)
            }
            #endif

            var data: [String: Any] = [
                "direction": direction,
                "velocity": velocity,
                "action": "swipe"
            ]
            if let query = query {
                data["query"] = query
            }
            return .success(responseData: data)
        } catch ElementResolverError.elementNotFound(let msg) {
            return .elementNotFound(message: msg)
        } catch ElementResolverError.invalidQuery(let msg) {
            return .invalidQuery(message: msg)
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    static func responseData(from resolution: Resolution) -> Data {
        switch resolution {
        case .success(let data):
            return HTTPResponseBuilder.json(data)
        case .elementNotFound(let msg):
            return HTTPResponseBuilder.error(msg, code: "element_not_found")
        case .invalidQuery(let msg):
            return HTTPResponseBuilder.error(msg, code: "invalid_query")
        case .invalidDirection(let direction):
            return HTTPResponseBuilder.error(
                "Invalid direction: \(direction). Use up, down, left, or right.",
                code: "invalid_direction"
            )
        case .waitTimeout(let query, let failed, let lastState, let timeoutMs):
            return TapHandler.waitTimeoutResponse(
                query: query,
                failedPredicates: failed,
                lastState: lastState,
                timeoutMs: timeoutMs
            )
        case .failed(let msg):
            return HTTPResponseBuilder.error(msg, code: "swipe_failed", status: 500)
        }
    }
}
