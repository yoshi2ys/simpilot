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
        let args = Self.parseWaitArgs(from: json)
        let resolution = Self.resolveAndTap(
            query: query,
            wait: args,
            gesture: .tap,
            in: app
        )
        return Self.responseData(from: resolution)
    }

    // MARK: - Shared resolution path

    struct Gesture {
        let onCoord: (XCUICoordinate) -> Void
        let onElement: (XCUIElement) -> Void

        static let tap = Gesture(
            onCoord: { $0.tap() },
            onElement: { $0.tap() }
        )
        static func longPress(duration: Double) -> Gesture {
            Gesture(
                onCoord: { $0.press(forDuration: duration) },
                onElement: { $0.press(forDuration: duration) }
            )
        }
        static let doubleTap = Gesture(
            onCoord: { $0.doubleTap() },
            onElement: { $0.doubleTap() }
        )
    }

    struct WaitArgs {
        let predicates: [Predicate]
        let timeoutMs: Int
        let pollIntervalMs: Int
    }

    /// Outcome of `awaitPredicates`. Shared between TapHandler (which hands
    /// the polled element into its coord tap) and SwipeHandler (which
    /// discards the polled element and resolves the swipe target via
    /// ElementResolver — swipe needs an XCUIElement, not a coordinate).
    enum WaitGate {
        case notNeeded
        case satisfied(element: DebugDescriptionParser.FoundElement?)
        case timedOut(lastState: [String: Any]?, failedPredicates: [String])
    }

    enum Resolution {
        case success(element: [String: Any])
        case elementNotFound(query: String)
        case waitTimeout(
            query: String,
            failedPredicates: [String],
            lastState: [String: Any]?,
            timeoutMs: Int
        )
        case noElementToTap(query: String)
        case tapFailed(query: String, reason: String)
    }

    static func parseWaitArgs(from json: [String: Any]) -> WaitArgs {
        let timeoutMs = (json["timeout_ms"] as? Int) ?? 0
        let predicates = parsePredicates(json["wait_until"]) ?? []
        let pollIntervalMs = (json["poll_interval_ms"] as? Int) ?? ElementPoller.defaultPollIntervalMs
        return WaitArgs(predicates: predicates, timeoutMs: timeoutMs, pollIntervalMs: pollIntervalMs)
    }

    /// Pure predicate: do we need to enter the poller at all?
    /// Hoisted so `SwipeHandlerTests` / `ActionHandlerTests` can unit-test the
    /// gate decision without needing a live XCUIApplication.
    static func needsPolling(wait: WaitArgs) -> Bool {
        return wait.timeoutMs > 0 || !wait.predicates.isEmpty
    }

    /// Pure predicate: predicate list that will actually be fed to
    /// `ElementPoller.waitUntil`. When the caller only sets a `timeout_ms`
    /// without explicit predicates, the poller needs something to check;
    /// `.exists` matches the legacy TapHandler behavior.
    static func effectivePredicates(wait: WaitArgs) -> [Predicate] {
        return wait.predicates.isEmpty ? [.exists] : wait.predicates
    }

    /// Shared wait gate for tap and swipe. Returns `.notNeeded` when the
    /// caller has no wait constraints (caller falls through to its own
    /// element resolution), `.satisfied` when predicates held (with the
    /// polled element for TapHandler's coord-tap reuse), or `.timedOut`
    /// when the deadline expired.
    static func awaitPredicates(
        query: String,
        wait: WaitArgs,
        in app: XCUIApplication
    ) -> WaitGate {
        guard needsPolling(wait: wait) else {
            return .notNeeded
        }
        let result = ElementPoller.waitUntil(
            query: query,
            predicates: effectivePredicates(wait: wait),
            timeoutMs: wait.timeoutMs,
            pollIntervalMs: wait.pollIntervalMs,
            in: app
        )
        switch result {
        case .satisfied(let element):
            return .satisfied(element: element)
        case .timedOut(let last, let failed):
            return .timedOut(lastState: last?.asDict, failedPredicates: failed)
        }
    }

    /// Resolve `query` via ElementPoller (when timeout or explicit predicates
    /// are set) or the legacy debugDescription fast path, then run `gesture`
    /// against the resolved target. Coordinate taps are preferred; typed-query
    /// fallback goes through `ElementResolver.resolve`.
    static func resolveAndTap(
        query: String,
        wait: WaitArgs,
        gesture: Gesture,
        in app: XCUIApplication
    ) -> Resolution {
        switch awaitPredicates(query: query, wait: wait, in: app) {
        case .satisfied(let element):
            // `not-exists` can satisfy with element == nil. Tapping nothing
            // is nonsense for a gesture handler, so surface it as an error
            // rather than silently no-op'ing.
            guard let element else {
                return .noElementToTap(query: query)
            }
            return performGesture(on: element, query: query, gesture: gesture, in: app)
        case .timedOut(let lastState, let failed):
            return .waitTimeout(
                query: query,
                failedPredicates: failed,
                lastState: lastState,
                timeoutMs: wait.timeoutMs
            )
        case .notNeeded:
            break
        }

        #if !os(tvOS)
        if let found = DebugDescriptionParser.findElement(query: query, in: app) {
            let failure = catchObjCException {
                let coord = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
                    .withOffset(CGVector(dx: found.centerX, dy: found.centerY))
                gesture.onCoord(coord)
            }
            if failure == nil {
                return .success(element: found.asDict)
            }
            // Coordinate gesture failed (e.g. visionOS spatial windows) —
            // fall through to ElementResolver.
        } else {
            // debugDescription miss is authoritative for bare labels and
            // `#identifier` queries. Only typed queries (`button:`, `text:`)
            // need the ElementResolver fallback.
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            if !trimmed.contains(":") {
                return .elementNotFound(query: query)
            }
        }
        #endif

        do {
            let element = try ElementResolver.resolve(query: query, in: app)
            #if os(tvOS)
            XCUIRemote.shared.press(.select)
            #else
            gesture.onElement(element)
            #endif
            return .success(element: ElementResolver.describe(element))
        } catch {
            return .elementNotFound(query: query)
        }
    }

    private static func performGesture(
        on found: DebugDescriptionParser.FoundElement,
        query: String,
        gesture: Gesture,
        in app: XCUIApplication
    ) -> Resolution {
        #if os(tvOS)
        XCUIRemote.shared.press(.select)
        return .success(element: found.asDict)
        #else
        let failure = catchObjCException {
            let coord = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
                .withOffset(CGVector(dx: found.centerX, dy: found.centerY))
            gesture.onCoord(coord)
        }
        if let failure {
            return .tapFailed(query: query, reason: String(describing: failure))
        }
        return .success(element: found.asDict)
        #endif
    }

    /// Shared envelope for every wait-gate timeout across TapHandler,
    /// SwipeHandler, and future longpress/doubletap. Centralizing this keeps
    /// the wire shape (code/status/extra fields) from drifting between
    /// handlers — both must produce the same JSON so clients can dispatch
    /// on a single error code.
    static func waitTimeoutResponse(
        query: String,
        failedPredicates: [String],
        lastState: [String: Any]?,
        timeoutMs: Int
    ) -> Data {
        var extra: [String: Any] = [
            "query": query,
            "failed_predicates": failedPredicates,
            "timeout_ms": timeoutMs
        ]
        if let lastState {
            extra["last_state"] = lastState
        }
        return HTTPResponseBuilder.error(
            "Timed out waiting for predicates on query: \(query)",
            code: "wait_timeout",
            status: 408,
            extra: extra
        )
    }

    static func responseData(from resolution: Resolution) -> Data {
        switch resolution {
        case .success(let element):
            return HTTPResponseBuilder.json(["element": element])
        case .elementNotFound(let query):
            return HTTPResponseBuilder.error(
                "Element not found for query: \(query)",
                code: "element_not_found"
            )
        case .waitTimeout(let query, let failed, let lastState, let timeoutMs):
            return waitTimeoutResponse(
                query: query,
                failedPredicates: failed,
                lastState: lastState,
                timeoutMs: timeoutMs
            )
        case .noElementToTap(let query):
            return HTTPResponseBuilder.error(
                "tap with wait_until resolved to no element (query: \(query))",
                code: "no_element_to_tap"
            )
        case .tapFailed(let query, let reason):
            return HTTPResponseBuilder.error(
                "Coordinate tap failed for query \(query): \(reason)",
                code: "tap_failed"
            )
        }
    }

    static func parsePredicates(_ raw: Any?) -> [Predicate]? {
        guard let array = raw as? [String] else { return nil }
        let parsed = array.compactMap { Predicate.parseSimple($0) }
        return parsed.isEmpty ? nil : parsed
    }
}
