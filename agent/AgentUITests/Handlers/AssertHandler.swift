import Foundation
import XCTest

/// Evaluates a predicate against a UI element with "eventually" semantics.
/// On failure returns `assertion_failed` with the observed state so tests get
/// actionable diagnostics instead of a bare "false".
final class AssertHandler: @unchecked Sendable {
    private let appManager: AppManager

    init(appManager: AppManager) {
        self.appManager = appManager
    }

    func handle(_ request: HTTPRequest) -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let predicateName = json["predicate"] as? String,
              let query = json["query"] as? String,
              !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return HTTPResponseBuilder.error(
                "Missing 'predicate' or 'query' in request body",
                code: "invalid_request"
            )
        }

        guard let predicate = buildPredicate(name: predicateName, expected: json["expected"] as? String) else {
            return HTTPResponseBuilder.error(
                "Unknown predicate: \(predicateName)",
                code: "invalid_request"
            )
        }

        let timeoutMs = (json["timeout_ms"] as? Int) ?? 3000
        let pollIntervalMs = (json["poll_interval_ms"] as? Int) ?? ElementPoller.defaultPollIntervalMs
        let snapshotOnFail = (json["snapshot_on_fail"] as? Bool) ?? false

        let app = appManager.currentApp()
        let result = ElementPoller.waitUntil(
            query: query,
            predicates: [predicate],
            timeoutMs: timeoutMs,
            pollIntervalMs: pollIntervalMs,
            in: app
        )

        switch result {
        case .satisfied(let element):
            var data: [String: Any] = [
                "predicate": predicate.name,
                "query": query,
                "passed": true
            ]
            if let element {
                data["observed"] = element.asDict
            }
            return HTTPResponseBuilder.json(data)

        case .timedOut(let lastElement, _):
            var extra: [String: Any] = [
                "predicate": predicate.name,
                "query": query,
                "timeout_ms": timeoutMs
            ]
            if let lastElement {
                extra["observed"] = lastElement.asDict
            }
            if snapshotOnFail {
                extra["elements_snapshot"] = DebugDescriptionParser.parseActionableList(from: app)
            }
            return HTTPResponseBuilder.error(
                "Assertion failed: \(predicate.name) on query '\(query)'",
                code: "assertion_failed",
                status: 422,
                extra: extra
            )
        }
    }

    // Handles the full predicate set (including value/label which require an expected arg).
    // `Predicate.parseSimple` only covers the no-argument predicates used by tap --wait-until.
    private func buildPredicate(name: String, expected: String?) -> Predicate? {
        switch name.lowercased() {
        case "exists": return .exists
        case "not-exists", "notexists", "gone": return .notExists
        case "enabled": return .enabled
        case "value":
            guard let expected else { return nil }
            return .value(expected: expected)
        case "label":
            guard let expected else { return nil }
            return .label(expected: expected)
        default: return nil
        }
    }
}
