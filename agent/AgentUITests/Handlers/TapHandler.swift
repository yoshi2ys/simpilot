import Foundation
import XCTest

final class TapHandler: @unchecked Sendable {
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

        let app = appManager.currentApp()

        // Route through the poller when timeout_ms > 0 or wait_until is set.
        // Explicit predicates must be honored even with timeout_ms == 0, else
        // the caller's check silently falls through to the legacy fast path.
        let timeoutMs = (json["timeout_ms"] as? Int) ?? 0
        let hasExplicitWaitUntil = (json["wait_until"] as? [String])?.isEmpty == false
        if timeoutMs > 0 || hasExplicitWaitUntil {
            let predicates = parsePredicates(json["wait_until"]) ?? [.exists]
            let pollIntervalMs = (json["poll_interval_ms"] as? Int) ?? ElementPoller.defaultPollIntervalMs
            let result = ElementPoller.waitUntil(
                query: query,
                predicates: predicates,
                timeoutMs: timeoutMs,
                pollIntervalMs: pollIntervalMs,
                in: app
            )
            switch result {
            case .satisfied(let element):
                // An existence-satisfying result with a nil element means the caller asked
                // for e.g. `not-exists` — there's nothing to tap. Return an error instead of
                // silently no-op'ing, because `tap` must produce a tap.
                guard let element else {
                    return HTTPResponseBuilder.error(
                        "tap with wait_until resolved to no element (query: \(query))",
                        code: "no_element_to_tap"
                    )
                }
                return performCoordinateTap(on: element, query: query, app: app)
            case .timedOut(let lastElement, let failedPredicates):
                var extra: [String: Any] = [
                    "query": query,
                    "failed_predicates": failedPredicates,
                    "timeout_ms": timeoutMs
                ]
                if let lastElement {
                    extra["last_state"] = lastElement.asDict
                }
                return HTTPResponseBuilder.error(
                    "Timed out waiting for predicates on query: \(query)",
                    code: "wait_timeout",
                    status: 408,
                    extra: extra
                )
            }
        }

        // Legacy path (timeout_ms == 0): fast debugDescription resolve + coordinate tap.
        #if !os(tvOS)
        if let found = DebugDescriptionParser.findElement(query: query, in: app) {
            let coordTapFailed = catchObjCException {
                let coord = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
                    .withOffset(CGVector(dx: found.centerX, dy: found.centerY))
                coord.tap()
            }

            if coordTapFailed == nil {
                return HTTPResponseBuilder.json([
                    "element": found.asDict
                ])
            }
            // Coordinate tap failed (e.g. visionOS spatial windows) — fall through to element.tap()
        } else {
            // Element not found in debugDescription.
            // For bare and #identifier queries, this is authoritative — ElementResolver
            // would return a phantom proxy (0x0 frame) instead of an error.
            // Only typed queries (button:, text:, etc.) need the ElementResolver fallback.
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            if !trimmed.contains(":") {
                return HTTPResponseBuilder.error("Element not found for query: \(query)", code: "element_not_found")
            }
        }
        #endif

        // Fallback: XCUITest element resolution + native tap (typed queries only on this path)
        do {
            let element = try ElementResolver.resolve(query: query, in: app)
            #if os(tvOS)
            XCUIRemote.shared.press(.select)
            #else
            element.tap()
            #endif
            return HTTPResponseBuilder.json(["element": ElementResolver.describe(element)])
        } catch {
            return HTTPResponseBuilder.error("Element not found for query: \(query)", code: "element_not_found")
        }
    }

    // MARK: - Helpers

    private func performCoordinateTap(
        on found: DebugDescriptionParser.FoundElement,
        query: String,
        app: XCUIApplication
    ) -> Data {
        #if os(tvOS)
        XCUIRemote.shared.press(.select)
        return HTTPResponseBuilder.json(["element": found.asDict])
        #else
        let failure = catchObjCException {
            let coord = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
                .withOffset(CGVector(dx: found.centerX, dy: found.centerY))
            coord.tap()
        }
        if let failure {
            return HTTPResponseBuilder.error(
                "Coordinate tap failed for query \(query): \(failure)",
                code: "tap_failed"
            )
        }
        return HTTPResponseBuilder.json(["element": found.asDict])
        #endif
    }

    private func parsePredicates(_ raw: Any?) -> [Predicate]? {
        guard let array = raw as? [String] else { return nil }
        let parsed = array.compactMap { Predicate.parseSimple($0) }
        return parsed.isEmpty ? nil : parsed
    }
}
