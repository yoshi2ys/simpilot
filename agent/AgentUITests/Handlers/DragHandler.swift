import Foundation
import XCTest

final class DragHandler: @unchecked Sendable {
    private let appManager: AppManager

    init(appManager: AppManager) {
        self.appManager = appManager
    }

    func handle(_ request: HTTPRequest) -> Data {
        #if os(tvOS)
        return HTTPResponseBuilder.error("drag is not supported on tvOS", code: "unsupported_platform")
        #else
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            return HTTPResponseBuilder.error("Invalid request body", code: "invalid_request")
        }

        let query = json["query"] as? String
        let toQuery = json["to_query"] as? String
        let toX = json["to_x"] as? Double
        let toY = json["to_y"] as? Double
        let fromX = json["from_x"] as? Double
        let fromY = json["from_y"] as? Double
        let duration = json["duration"] as? Double ?? 0.5

        // Validate mutual exclusivity
        let hasQuery = query != nil && !query!.isEmpty
        let hasFromCoord = fromX != nil || fromY != nil
        if hasQuery && hasFromCoord {
            return HTTPResponseBuilder.error(
                "Cannot specify both 'query' and 'from_x'/'from_y'",
                code: "invalid_request"
            )
        }

        let hasToQuery = toQuery != nil && !toQuery!.isEmpty
        let hasToCoord = toX != nil || toY != nil
        if hasToQuery && hasToCoord {
            return HTTPResponseBuilder.error(
                "Cannot specify both 'to_query' and 'to_x'/'to_y'",
                code: "invalid_request"
            )
        }

        guard duration >= 0 else {
            return HTTPResponseBuilder.error(
                "duration must be >= 0",
                code: "invalid_request"
            )
        }

        let app = appManager.currentApp()

        // Resolve source coordinate
        let sourceCoord: XCUICoordinate
        if let fromX, let fromY {
            sourceCoord = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
                .withOffset(CGVector(dx: fromX, dy: fromY))
        } else if let query, !query.isEmpty {
            do {
                let element = try ElementResolver.resolve(query: query, in: app)
                sourceCoord = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            } catch ElementResolverError.elementNotFound(let msg) {
                return HTTPResponseBuilder.error(msg, code: "element_not_found")
            } catch ElementResolverError.invalidQuery(let msg) {
                return HTTPResponseBuilder.error(msg, code: "invalid_query")
            } catch {
                return HTTPResponseBuilder.error(error.localizedDescription, code: "drag_failed", status: 500)
            }
        } else {
            return HTTPResponseBuilder.error(
                "Must specify 'query' or both 'from_x' and 'from_y'",
                code: "invalid_request"
            )
        }

        // Resolve target coordinate
        let targetCoord: XCUICoordinate
        if let toQuery, !toQuery.isEmpty {
            do {
                let element = try ElementResolver.resolve(query: toQuery, in: app)
                targetCoord = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            } catch ElementResolverError.elementNotFound(let msg) {
                return HTTPResponseBuilder.error(msg, code: "element_not_found")
            } catch ElementResolverError.invalidQuery(let msg) {
                return HTTPResponseBuilder.error(msg, code: "invalid_query")
            } catch {
                return HTTPResponseBuilder.error(error.localizedDescription, code: "drag_failed", status: 500)
            }
        } else if let toX, let toY {
            targetCoord = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
                .withOffset(CGVector(dx: toX, dy: toY))
        } else {
            return HTTPResponseBuilder.error(
                "Must specify 'to_query' or both 'to_x' and 'to_y'",
                code: "invalid_request"
            )
        }

        // Execute drag
        let failure = catchObjCException {
            sourceCoord.press(forDuration: duration, thenDragTo: targetCoord)
        }
        if let failure {
            return HTTPResponseBuilder.error(
                "Drag failed: \(failure)",
                code: "drag_failed",
                status: 500
            )
        }

        var data: [String: Any] = [
            "action": "drag",
            "duration": duration
        ]
        if let query { data["query"] = query }
        if let toQuery { data["to"] = toQuery }
        if let toX { data["to_x"] = toX }
        if let toY { data["to_y"] = toY }
        if let fromX { data["from_x"] = fromX }
        if let fromY { data["from_y"] = fromY }

        return HTTPResponseBuilder.json(data)
        #endif
    }
}
