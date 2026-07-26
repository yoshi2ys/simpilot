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
        case .aliasRejected:
            return AliasResponse.unsupported("wait", reason: .cannotBePolled)
        case .rowFailed(let error):
            return RowResponse.error(error)
        case .satisfied:
            return HTTPResponseBuilder.json([
                "found": shouldExist,
                "query": query,
                "timeout": timeoutSeconds
            ])
        case .timedOut:
            // Both codes are spelled out at the call rather than picked into a
            // variable: `ErrorHintTests` reads `code:` literals out of the source
            // to prove every code has a hint decision, and a code assembled at
            // runtime is invisible to it.
            return shouldExist
                ? HTTPResponseBuilder.error(
                    "Element did not appear within \(timeoutSeconds)s: \(query)",
                    code: "element_not_found"
                )
                : HTTPResponseBuilder.error(
                    "Element still exists after \(timeoutSeconds)s: \(query)",
                    code: "element_still_exists"
                )
        }
    }
}
