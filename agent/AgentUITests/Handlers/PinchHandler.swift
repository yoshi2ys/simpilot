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

        // pinch(withScale:velocity:) expects velocity in scale-factor-per-second.
        // XCUIGestureVelocity rawValues are pixels-per-second (for swipe) and
        // .default is 0, which throws NSInvalidArgumentException for pinch.
        // Use concrete CGFloat values appropriate for scale-factor velocity.
        let pinchVelocity: CGFloat
        switch velocityName {
        case "slow": pinchVelocity = 1.0
        case "fast": pinchVelocity = 15.0
        case "default": pinchVelocity = 5.0
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

        // Velocity sign must match scale direction: positive for zoom in
        // (scale > 1), negative for zoom out (scale < 1).
        let signedVelocity = scale >= 1.0 ? pinchVelocity : -pinchVelocity

        let failure = catchObjCException {
            target.pinch(withScale: CGFloat(scale), velocity: signedVelocity)
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
