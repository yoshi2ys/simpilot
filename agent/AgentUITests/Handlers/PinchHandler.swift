import Foundation
import XCTest

final class PinchHandler: @unchecked Sendable {
    private let appManager: AppManager

    init(appManager: AppManager) {
        self.appManager = appManager
    }

    func handle(_ request: HTTPRequest) -> Data {
        #if os(tvOS)
        return HTTPResponseBuilder.error("pinch is not supported on tvOS", code: "unsupported_platform")
        #else
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let scale = json["scale"] as? Double else {
            return HTTPResponseBuilder.error(
                "Missing or invalid 'scale' in request body",
                code: "invalid_request"
            )
        }

        guard scale > 0 else {
            return HTTPResponseBuilder.error(
                "scale must be greater than 0",
                code: "invalid_request"
            )
        }

        let query = json["query"] as? String
        let velocityName = json["velocity"] as? String ?? "default"

        let pinchVelocity: XCUIGestureVelocity
        switch velocityName {
        case "slow": pinchVelocity = .slow
        case "fast": pinchVelocity = .fast
        case "default": pinchVelocity = .default
        default:
            return HTTPResponseBuilder.error(
                "Invalid velocity: \(velocityName). Use slow, default, or fast.",
                code: "invalid_request"
            )
        }

        let app = appManager.currentApp()

        let target: XCUIElement
        if let query, !query.isEmpty {
            do {
                target = try ElementResolver.resolve(query: query, in: app)
            } catch ElementResolverError.elementNotFound(let msg) {
                return HTTPResponseBuilder.error(msg, code: "element_not_found")
            } catch ElementResolverError.invalidQuery(let msg) {
                return HTTPResponseBuilder.error(msg, code: "invalid_query")
            } catch {
                return HTTPResponseBuilder.error(error.localizedDescription, code: "pinch_failed", status: 500)
            }
        } else {
            target = app
        }

        let failure = catchObjCException {
            target.pinch(withScale: CGFloat(scale), velocity: CGFloat(pinchVelocity.rawValue))
        }
        if let failure {
            return HTTPResponseBuilder.error(
                "Pinch failed: \(failure)",
                code: "pinch_failed",
                status: 500
            )
        }

        var data: [String: Any] = [
            "action": "pinch",
            "scale": scale,
            "velocity": velocityName
        ]
        if let query { data["query"] = query }

        return HTTPResponseBuilder.json(data)
        #endif
    }
}
