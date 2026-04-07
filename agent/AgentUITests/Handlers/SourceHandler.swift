import Foundation
import XCTest

final class SourceHandler: @unchecked Sendable {
    private let appManager: AppManager

    init(appManager: AppManager) {
        self.appManager = appManager
    }

    func handle(_ request: HTTPRequest) -> Data {
        let app: XCUIApplication
        do {
            app = try appManager.resolveApp(bundleId: request.queryParams["bundleId"])
        } catch {
            return HTTPResponseBuilder.error(error.localizedDescription, code: "activate_failed")
        }
        let source = app.debugDescription
        return HTTPResponseBuilder.json(["source": source])
    }
}
