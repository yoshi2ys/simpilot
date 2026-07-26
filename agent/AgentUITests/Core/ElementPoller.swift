import Foundation
import XCTest

/// Polls the UI via DebugDescriptionParser until all predicates hold or the deadline expires.
/// Shared by TapHandler (atomic wait-and-tap), AssertHandler, and WaitHandler.
enum ElementPoller {

    enum Result {
        /// All predicates held. Contains the element that matched (or nil for a successful not-exists check).
        case satisfied(element: DebugDescriptionParser.FoundElement?)
        /// The query was an `@eN` alias. Polling for one is incoherent — an alias
        /// names a list that was already read, so it cannot "become" valid — and
        /// this is a `Result` case rather than a guard at each call site so a new
        /// poller caller cannot forget it: the switch stops compiling instead.
        case aliasRejected(query: String)
        /// The query was an `@rN` / `@lMrN` row selector that never resolved before
        /// the deadline. Polling one *is* coherent — it is re-derived from the live
        /// tree every tick — so this is a timeout with a diagnosis, not a refusal:
        /// it says whether the screen had no list, an ambiguous one, or too few
        /// rows, which `.timedOut` alone could not.
        case rowFailed(RowResolutionError)
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
    ///   - query: DebugDescriptionParser query (bare label, `#identifier`, `type:value`,
    ///     or an `@rN` / `@lMrN` row selector; an `@eN` alias is refused).
    ///   - predicates: conditions that must all hold simultaneously on a single observation.
    ///   - timeoutMs: maximum time to wait. 0 = check once and return immediately (no retry).
    ///   - pollIntervalMs: sleep between polls. Ignored if timeoutMs == 0.
    ///   - app: the XCUIApplication to query.
    ///
    /// Behavior:
    ///   - On each poll, `locate` is called once, then every predicate is evaluated against the result.
    ///   - Predicates evaluate against the current observation only; they do not remember prior polls.
    ///   - If every predicate holds, returns `.satisfied(element:)` with the observed element (may be nil
    ///     for predicates like `not-exists`).
    ///   - If the deadline passes, returns `.timedOut(lastElement:, failedPredicates:)` with the predicates
    ///     that were still failing on the final observation — or `.rowFailed` when the final observation
    ///     could not place a row selector at all, which is a diagnosis the predicate list cannot carry.
    static func waitUntil(
        query: String,
        predicates: [Predicate],
        timeoutMs: Int,
        pollIntervalMs: Int = defaultPollIntervalMs,
        in app: XCUIApplication
    ) -> Result {
        precondition(!predicates.isEmpty, "ElementPoller requires at least one predicate")
        guard !AliasResolver.isAlias(query) else { return .aliasRejected(query: query) }

        let deadline = Date().addingTimeInterval(TimeInterval(max(timeoutMs, 0)) / 1000.0)
        let sleepInterval = TimeInterval(max(pollIntervalMs, 0)) / 1000.0
        // .hittable is deferred until cheap pass clears (forces an extra IPC);
        // .stable is stateful and advanced via StablePredicate.advance.
        let cheapPredicates = predicates.filter { $0 != .hittable && $0 != .stable }
        let needsHittable = predicates.contains(.hittable)
        let needsStable = predicates.contains(.stable)
        var stableState = StablePredicate.State.initial

        while true {
            var observed: DebugDescriptionParser.FoundElement?
            // Per-tick, and only reported once the deadline passes: a list still
            // being rendered resolves on a later tick, so returning the first
            // tick's failure would defeat the wait the caller asked for.
            var rowFailure: RowResolutionError?
            switch DebugDescriptionParser.locate(query: query, in: app) {
            case .found(let element): observed = element
            case .notFound: observed = nil
            case .rowFailed(let error): rowFailure = error
            }
            var failed = cheapPredicates
                .filter { !PredicateEvaluator.matches($0, element: observed) }
                .map { $0.name }

            // Advance stable state every tick even when other predicates fail:
            // history must keep accumulating so `hittable,stable` can progress
            // while hittable is still resolving.
            let stableSatisfied = StablePredicate.advance(&stableState, observedFrame: observed?.frame)
            if needsStable, !stableSatisfied {
                failed.append(Predicate.stable.name)
            }

            // `checkHittability` re-queries XCUITest by label or identifier, and a
            // row often has neither — nameless rows are the reason a positional
            // handle exists at all. `resolveIsHittable` reports `false` for those,
            // which would be an answer simpilot cannot know: refuse instead, the way
            // `elementDict` emits `null` rather than a plausible default.
            if failed.isEmpty, needsHittable, let element = observed,
               element.label.isEmpty, element.identifier.isEmpty,
               let selector = RowSelector.parse(query) {
                return .rowFailed(.notCheckable(selector, predicate: Predicate.hittable.name))
            }

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

            // `rowFailure` beats a satisfied predicate set, because it does not mean
            // "no such element": it means the selector could not be placed on this
            // screen at all. `not-exists` is satisfied by `observed == nil`, so
            // without this an ambiguous `@r3` — or one on a screen with no list —
            // would return `success: true, found: false` for a query nobody could
            // resolve, which is the silent success the project forbids.
            if failed.isEmpty, rowFailure == nil {
                return .satisfied(element: observed)
            }
            if timeoutMs <= 0 || Date() >= deadline {
                // The row diagnosis wins over the predicate list: "this screen has
                // two lists, so @r3 is ambiguous" is actionable where "exists
                // failed" sends the caller looking for a missing element.
                if let rowFailure { return .rowFailed(rowFailure) }
                return .timedOut(lastElement: observed, failedPredicates: failed)
            }
            // Waiting is watching for change, so the next tick must look at the
            // screen and not at the tree this one already read (SU5). Without the
            // drop, a `perBatch` batch would poll one frozen observation to its
            // deadline.
            AXTree.settle(sleepInterval)
        }
    }
}
