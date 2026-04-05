import Foundation
import XCTest

final class SourceHandler: @unchecked Sendable {
    private let appManager: AppManager

    init(appManager: AppManager) {
        self.appManager = appManager
    }

    func handle(_ request: HTTPRequest) -> Data {
        let app = appManager.currentApp()
        let source = app.debugDescription
        return HTTPResponseBuilder.json(["source": source])
    }
}
