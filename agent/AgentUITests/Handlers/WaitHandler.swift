import Foundation
import XCTest

final class WaitHandler: @unchecked Sendable {
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

        let timeout = json["timeout"] as? Double ?? 10.0
        let shouldExist = json["exists"] as? Bool ?? true

        let app = appManager.currentApp()

        let element: XCUIElement
        do {
            element = try ElementResolver.lookup(query: query, in: app)
        } catch {
            return HTTPResponseBuilder.error(
                error.localizedDescription,
                code: "invalid_query"
            )
        }

        if shouldExist {
            let found = element.waitForExistence(timeout: timeout)
            if found {
                return HTTPResponseBuilder.json(
                    ["found": true, "query": query, "timeout": timeout]
                )
            } else {
                return HTTPResponseBuilder.error(
                    "Element did not appear within \(timeout)s: \(query)",
                    code: "element_not_found"
                )
            }
        } else {
            let deadline = Date().addingTimeInterval(timeout)
            var disappeared = !element.exists
            while !disappeared && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.25)
                disappeared = !element.exists
            }
            if disappeared {
                return HTTPResponseBuilder.json(
                    ["found": false, "query": query, "timeout": timeout]
                )
            } else {
                return HTTPResponseBuilder.error(
                    "Element still exists after \(timeout)s: \(query)",
                    code: "element_still_exists"
                )
            }
        }
    }
}
