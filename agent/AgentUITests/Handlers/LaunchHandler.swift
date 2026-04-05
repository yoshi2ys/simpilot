import Foundation
import XCTest

final class LaunchHandler: @unchecked Sendable {
    private let appManager: AppManager

    init(appManager: AppManager) {
        self.appManager = appManager
    }

    func handle(_ request: HTTPRequest) -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let bundleId = json["bundleId"] as? String else {
            return HTTPResponseBuilder.error(
                "Missing or invalid 'bundleId' in request body",
                code: "invalid_request"
            )
        }

        let app = appManager.launch(bundleId: bundleId)
        let state: String
        switch app.state {
        case .notRunning: state = "notRunning"
        case .runningBackgroundSuspended: state = "runningBackgroundSuspended"
        case .runningBackground: state = "runningBackground"
        case .runningForeground: state = "runningForeground"
        case .unknown: state = "unknown"
        @unknown default: state = "unknown"
        }

        return HTTPResponseBuilder.json(["bundleId": bundleId, "state": state])
    }
}
