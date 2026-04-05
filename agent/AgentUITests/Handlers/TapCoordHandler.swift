import Foundation
import XCTest

final class TapCoordHandler: @unchecked Sendable {
    private let appManager: AppManager

    init(appManager: AppManager) {
        self.appManager = appManager
    }

    func handle(_ request: HTTPRequest) -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let x = json["x"] as? Double,
              let y = json["y"] as? Double else {
            return HTTPResponseBuilder.error(
                "Missing or invalid 'x' and 'y' in request body",
                code: "invalid_request"
            )
        }

        let app = appManager.currentApp()
        let normalized = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        let target = normalized.withOffset(CGVector(dx: x, dy: y))
        target.tap()

        return HTTPResponseBuilder.json(["x": x, "y": y, "action": "tap"])
    }
}
