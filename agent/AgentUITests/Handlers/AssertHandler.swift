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

        let predicate: Predicate
        switch buildPredicate(name: predicateName, expected: json["expected"] as? String) {
        case .success(let p):
            predicate = p
        case .failure(.unknown):
            return HTTPResponseBuilder.error(
                "Unknown predicate: \(predicateName)",
                code: "invalid_request"
            )
        case .failure(.missingExpected):
            return HTTPResponseBuilder.error(
                "Predicate '\(predicateName)' requires an 'expected' argument",
                code: "invalid_request"
            )
        case .failure(.matcher(.emptyContains)):
            return HTTPResponseBuilder.error(
                "contains: matcher requires a non-empty substring",
                code: "invalid_request"
            )
        case .failure(.matcher(.invalidRegex(let pattern, let reason))):
            return HTTPResponseBuilder.error(
                "Invalid regex '\(pattern)': \(reason)",
                code: "invalid_regex"
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

    enum BuildError: Error {
        case unknown
        case missingExpected
        case matcher(StringMatcher.ParseError)
    }

    // Full predicate set for assert. `Predicate.parseSimple` handles the
    // no-argument subset used by `tap --wait-until`.
    private func buildPredicate(name: String, expected: String?) -> Result<Predicate, BuildError> {
        switch name.lowercased() {
        case "exists": return .success(.exists)
        case "not-exists", "notexists", "gone": return .success(.notExists)
        case "enabled": return .success(.enabled)
        case "hittable": return .success(.hittable)
        case "value":
            guard let expected else { return .failure(.missingExpected) }
            return StringMatcher.parse(expected).map { .value($0) }.mapError { .matcher($0) }
        case "label":
            guard let expected else { return .failure(.missingExpected) }
            return StringMatcher.parse(expected).map { .label($0) }.mapError { .matcher($0) }
        default: return .failure(.unknown)
        }
    }
}
