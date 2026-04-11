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

        // Legacy wire format: `timeout` is seconds (Double), `exists` is a bool.
        // Preserved for backward compatibility with existing clients.
        let timeoutSeconds = json["timeout"] as? Double ?? 10.0
        let shouldExist = json["exists"] as? Bool ?? true
        let predicate: Predicate = shouldExist ? .exists : .notExists

        let app = appManager.currentApp()
        let result = ElementPoller.waitUntil(
            query: query,
            predicates: [predicate],
            timeoutMs: Int(timeoutSeconds * 1000),
            in: app
        )

        switch result {
        case .satisfied:
            return HTTPResponseBuilder.json([
                "found": shouldExist,
                "query": query,
                "timeout": timeoutSeconds
            ])
        case .timedOut:
            let code = shouldExist ? "element_not_found" : "element_still_exists"
            let message = shouldExist
                ? "Element did not appear within \(timeoutSeconds)s: \(query)"
                : "Element still exists after \(timeoutSeconds)s: \(query)"
            return HTTPResponseBuilder.error(message, code: code)
        }
    }
}
