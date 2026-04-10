import Foundation
import XCTest

final class WaitHandler: @unchecked Sendable {
    private let appManager: AppManager

    init(appManager: AppManager) {
        self.appManager = appManager
    }

    func handle(_ request: HTTPRequest) -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let query = json["query"] as? String,
              !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return HTTPResponseBuilder.error(
                "Missing or invalid 'query' in request body",
                code: "invalid_request"
            )
        }

        let timeout = json["timeout"] as? Double ?? 10.0
        let shouldExist = json["exists"] as? Bool ?? true

        let app = appManager.currentApp()
        let deadline = Date().addingTimeInterval(timeout)

        // Poll using DebugDescriptionParser instead of XCUIElement.waitForExistence().
        // waitForExistence() on bare/identifier queries crashes the agent because
        // XCUITest throws uncatchable NSExceptions on phantom element proxies.
        if shouldExist {
            while Date() < deadline {
                if DebugDescriptionParser.findElement(query: query, in: app) != nil {
                    return HTTPResponseBuilder.json(
                        ["found": true, "query": query, "timeout": timeout]
                    )
                }
                Thread.sleep(forTimeInterval: 0.25)
            }
            return HTTPResponseBuilder.error(
                "Element did not appear within \(timeout)s: \(query)",
                code: "element_not_found"
            )
        } else {
            while Date() < deadline {
                if DebugDescriptionParser.findElement(query: query, in: app) == nil {
                    return HTTPResponseBuilder.json(
                        ["found": false, "query": query, "timeout": timeout]
                    )
                }
                Thread.sleep(forTimeInterval: 0.25)
            }
            return HTTPResponseBuilder.error(
                "Element still exists after \(timeout)s: \(query)",
                code: "element_still_exists"
            )
        }
    }
}
