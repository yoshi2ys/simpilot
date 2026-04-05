import Foundation
import XCTest

final class TypeHandler: @unchecked Sendable {
    private let appManager: AppManager

    init(appManager: AppManager) {
        self.appManager = appManager
    }

    func handle(_ request: HTTPRequest) -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let text = json["text"] as? String else {
            return HTTPResponseBuilder.error(
                "Missing or invalid 'text' in request body",
                code: "invalid_request"
            )
        }

        let query = json["query"] as? String
        let app = appManager.currentApp()

        if let query = query, !query.isEmpty {
            guard let found = DebugDescriptionParser.findElement(query: query, in: app) else {
                return HTTPResponseBuilder.error(
                    "Element not found for query: \(query)",
                    code: "element_not_found"
                )
            }
            let coord = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
                .withOffset(CGVector(dx: found.centerX, dy: found.centerY))
            coord.tap()
        }

        app.typeText(text)

        var responseData: [String: Any] = ["text": text, "action": "type"]
        if let query = query { responseData["query"] = query }
        return HTTPResponseBuilder.json(responseData)
    }
}
