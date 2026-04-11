import Foundation
import XCTest

/// Polls the UI via DebugDescriptionParser until all predicates hold or the deadline expires.
/// Shared by TapHandler (atomic wait-and-tap), AssertHandler, and WaitHandler.
enum ElementPoller {

    enum Result {
        /// All predicates held. Contains the element that matched (or nil for a successful not-exists check).
        case satisfied(element: DebugDescriptionParser.FoundElement?)
        /// The deadline expired before all predicates held.
        /// `lastElement` is whatever we last observed (may be nil); `failedPredicates` lists the predicate names
        /// that were not satisfied on the final observation.
        case timedOut(lastElement: DebugDescriptionParser.FoundElement?, failedPredicates: [String])
    }

    /// Default poll interval matches WaitHandler's historical value (0.25s).
    static let defaultPollIntervalMs: Int = 250

    /// Poll until every predicate in `predicates` holds, or until `timeoutMs` elapses.
    ///
    /// - Parameters:
    ///   - query: DebugDescriptionParser query (bare label, `#identifier`, or `type:value`).
    ///   - predicates: conditions that must all hold simultaneously on a single observation.
    ///   - timeoutMs: maximum time to wait. 0 = check once and return immediately (no retry).
    ///   - pollIntervalMs: sleep between polls. Ignored if timeoutMs == 0.
    ///   - app: the XCUIApplication to query.
    ///
    /// Behavior:
    ///   - On each poll, `findElement` is called once, then every predicate is evaluated against the result.
    ///   - Predicates evaluate against the current observation only; they do not remember prior polls.
    ///   - If every predicate holds, returns `.satisfied(element:)` with the observed element (may be nil
    ///     for predicates like `not-exists`).
    ///   - If the deadline passes, returns `.timedOut(lastElement:, failedPredicates:)` with the predicates
    ///     that were still failing on the final observation.
    static func waitUntil(
        query: String,
        predicates: [Predicate],
        timeoutMs: Int,
        pollIntervalMs: Int = defaultPollIntervalMs,
        in app: XCUIApplication
    ) -> Result {
        precondition(!predicates.isEmpty, "ElementPoller requires at least one predicate")

        let deadline = Date().addingTimeInterval(TimeInterval(max(timeoutMs, 0)) / 1000.0)
        let sleepInterval = TimeInterval(max(pollIntervalMs, 0)) / 1000.0
        let cheapPredicates = predicates.filter { $0 != .hittable }
        let needsHittable = predicates.contains(.hittable)

        while true {
            var observed = DebugDescriptionParser.findElement(query: query, in: app)
            var failed = cheapPredicates
                .filter { !PredicateEvaluator.matches($0, element: observed) }
                .map { $0.name }

            // Defer the .hittable IPC until cheap predicates clear: isHittable forces
            // an accessibility snapshot (~50–750ms depending on tree density), so
            // skipping it when exists/enabled/label already failed saves significant
            // wall time across the retry loop.
            if failed.isEmpty, needsHittable {
                if let element = observed {
                    let check = DebugDescriptionParser.checkHittability(for: element, in: app)
                    if check.duration >= 0.5 {
                        print("[simpilot] hittable_check_slow: query=\(query) ms=\(Int(check.duration * 1000))")
                    }
                    observed?.hittable = check.hittable
                    if !check.hittable {
                        failed = [Predicate.hittable.name]
                    }
                } else {
                    failed = [Predicate.hittable.name]
                }
            }

            if failed.isEmpty {
                return .satisfied(element: observed)
            }
            if timeoutMs <= 0 || Date() >= deadline {
                return .timedOut(lastElement: observed, failedPredicates: failed)
            }
            Thread.sleep(forTimeInterval: sleepInterval)
        }
    }
}
