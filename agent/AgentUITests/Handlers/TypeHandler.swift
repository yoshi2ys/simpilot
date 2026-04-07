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
        let method = json["method"] as? String ?? "auto"
        let app = appManager.currentApp()

        #if !os(tvOS)
        var targetCoord: XCUICoordinate?
        if let query = query, !query.isEmpty {
            guard let found = DebugDescriptionParser.findElement(query: query, in: app) else {
                return HTTPResponseBuilder.error(
                    "Element not found for query: \(query)",
                    code: "element_not_found"
                )
            }
            targetCoord = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
                .withOffset(CGVector(dx: found.centerX, dy: found.centerY))
            targetCoord?.tap()
        }
        #else
        if let query = query, !query.isEmpty {
            do {
                let _ = try ElementResolver.resolve(query: query, in: app)
                XCUIRemote.shared.press(.select)
            } catch {
                return HTTPResponseBuilder.error(
                    "Element not found for query: \(query)",
                    code: "element_not_found"
                )
            }
        }
        #endif

        #if os(tvOS)
        let (usedMethod, inputError) = PasteHelper.performTextInput(text, method: method, at: nil, in: app)
        #else
        let (usedMethod, inputError) = PasteHelper.performTextInput(text, method: method, at: targetCoord, in: app)
        #endif
        if let inputError { return inputError }

        var responseData: [String: Any] = ["text": text, "action": "type", "method": usedMethod]
        if let query = query { responseData["query"] = query }
        return HTTPResponseBuilder.json(responseData)
    }
}
