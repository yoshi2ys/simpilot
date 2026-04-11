import Foundation
import XCTest

final class DoubleTapHandler: @unchecked Sendable {
    private let appManager: AppManager

    init(appManager: AppManager) {
        self.appManager = appManager
    }

    func handle(_ request: HTTPRequest) -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let query = json["query"] as? String else {
            return HTTPResponseBuilder.error(
                "Missing or invalid 'query' in request body",
                code: "invalid_request"
            )
        }

        let app = appManager.currentApp()
        let resolution = TapHandler.resolveAndTap(
            query: query,
            wait: TapHandler.parseWaitArgs(from: json),
            gesture: .doubleTap,
            in: app
        )
        return TapHandler.responseData(from: resolution)
    }
}
