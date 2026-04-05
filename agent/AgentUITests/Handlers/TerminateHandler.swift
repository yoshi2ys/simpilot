import Foundation
import XCTest

final class TerminateHandler: @unchecked Sendable {
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

        appManager.terminate(bundleId: bundleId)

        return HTTPResponseBuilder.json(["bundleId": bundleId, "action": "terminated"])
    }
}
