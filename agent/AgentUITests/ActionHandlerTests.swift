import XCTest

/// Wave 3.1 regression guard.
///
/// These tests lock in that `ActionHandler` shares `TapHandler.resolveAndTap`
/// instead of its own debugDescription-only path. Before Wave 3.1 the tap case
/// in ActionHandler silently dropped `wait_until` / `timeout_ms` — any future
/// refactor that reintroduces that gap should trip at least one of these.
final class ActionHandlerTests: XCTestCase {

    // MARK: - parseWaitArgs

    func test_parseWaitArgs_extractsPredicatesAndTimeouts() {
        let body: [String: Any] = [
            "action": "tap",
            "query": "General",
            "wait_until": ["hittable", "stable"],
            "timeout_ms": 5000,
            "poll_interval_ms": 100
        ]
        let args = TapHandler.parseWaitArgs(from: body)
        XCTAssertEqual(args.predicates.map { $0.name }.sorted(), ["hittable", "stable"])
        XCTAssertEqual(args.timeoutMs, 5000)
        XCTAssertEqual(args.pollIntervalMs, 100)
    }

    func test_parseWaitArgs_defaultsWhenFieldsAbsent() {
        let body: [String: Any] = ["action": "tap", "query": "General"]
        let args = TapHandler.parseWaitArgs(from: body)
        XCTAssertTrue(args.predicates.isEmpty)
        XCTAssertEqual(args.timeoutMs, 0)
        XCTAssertEqual(args.pollIntervalMs, ElementPoller.defaultPollIntervalMs)
    }

    func test_parseWaitArgs_ignoresEmptyWaitUntilArray() {
        let body: [String: Any] = [
            "action": "tap",
            "query": "General",
            "wait_until": [String]()
        ]
        let args = TapHandler.parseWaitArgs(from: body)
        XCTAssertTrue(args.predicates.isEmpty)
    }

    func test_parseWaitArgs_ignoresUnknownPredicateNames() {
        let body: [String: Any] = [
            "action": "tap",
            "query": "General",
            "wait_until": ["nonsense", "hittable"]
        ]
        let args = TapHandler.parseWaitArgs(from: body)
        XCTAssertEqual(args.predicates.map { $0.name }, ["hittable"])
    }

    // MARK: - Pure wait-gate behavior

    func test_needsPolling_falseWhenNoConstraints() {
        let wait = TapHandler.WaitArgs(predicates: [], timeoutMs: 0, pollIntervalMs: 250)
        XCTAssertFalse(TapHandler.needsPolling(wait: wait))
    }

    func test_needsPolling_trueWhenTimeoutSet() {
        let wait = TapHandler.WaitArgs(predicates: [], timeoutMs: 1000, pollIntervalMs: 250)
        XCTAssertTrue(TapHandler.needsPolling(wait: wait))
    }

    /// Regression guard for the "explicit predicates honored even with
    /// timeout_ms == 0" rule from TapHandler. Without this, a caller passing
    /// only `wait_until=[hittable]` would silently fall through to the
    /// legacy fast path.
    func test_needsPolling_trueWhenPredicatesSetEvenIfTimeoutZero() {
        let wait = TapHandler.WaitArgs(predicates: [.hittable], timeoutMs: 0, pollIntervalMs: 250)
        XCTAssertTrue(TapHandler.needsPolling(wait: wait))
    }

    func test_effectivePredicates_defaultsToExistsWhenEmpty() {
        let wait = TapHandler.WaitArgs(predicates: [], timeoutMs: 1000, pollIntervalMs: 250)
        XCTAssertEqual(TapHandler.effectivePredicates(wait: wait).map { $0.name }, ["exists"])
    }

    func test_effectivePredicates_passesThroughExplicitSet() {
        let wait = TapHandler.WaitArgs(
            predicates: [.hittable, .stable],
            timeoutMs: 1000,
            pollIntervalMs: 250
        )
        XCTAssertEqual(
            TapHandler.effectivePredicates(wait: wait).map { $0.name }.sorted(),
            ["hittable", "stable"]
        )
    }

    // MARK: - Source-level wiring guards

    /// Structural test: ActionHandler's tap case must route through
    /// `TapHandler.resolveAndTap` (the shared path) and must not reintroduce
    /// its own debugDescription call. If a future refactor inlines element
    /// resolution back into ActionHandler, this test fails.
    func test_actionHandler_tapCase_routesThroughSharedHelper() throws {
        let source = try loadActionHandlerSource()
        XCTAssertTrue(
            source.contains("TapHandler.resolveAndTap"),
            "ActionHandler must call the shared TapHandler.resolveAndTap helper for the tap case."
        )
        // Tap case previously called DebugDescriptionParser.findElement directly.
        // The remaining reference in ActionHandler comes from the `type` case
        // (focus-by-coord), never from tap. If tap regresses to a direct
        // findElement call the count grows beyond the known 1 occurrence.
        let findElementOccurrences = source.components(separatedBy: "DebugDescriptionParser.findElement").count - 1
        XCTAssertLessThanOrEqual(
            findElementOccurrences,
            1,
            "ActionHandler.tap case must not call DebugDescriptionParser.findElement directly (only the type case may)."
        )
    }

    /// Same guard for swipe: `ElementResolver.resolve` should not appear in
    /// the swipe case anymore — the shared `SwipeHandler.resolveAndSwipe`
    /// helper owns element resolution.
    func test_actionHandler_swipeCase_routesThroughSharedHelper() throws {
        let source = try loadActionHandlerSource()
        XCTAssertTrue(
            source.contains("SwipeHandler.resolveAndSwipe"),
            "ActionHandler must call the shared SwipeHandler.resolveAndSwipe helper for the swipe case."
        )
    }

    /// Regression guard for Wave 3.1 iter 2 [major] finding: ActionHandler's
    /// swipe case must forward `wait:` into SwipeHandler.resolveAndSwipe, or
    /// `simpilot action swipe ... --wait-until hittable --timeout 5` silently
    /// no-op'd the wait gate. If a future refactor drops the parameter, this
    /// fails loudly at CI time.
    func test_actionHandler_swipeCase_forwardsWaitArgs() throws {
        let source = try loadActionHandlerSource()
        guard let swipeCaseStart = source.range(of: "case \"swipe\":") else {
            XCTFail("ActionHandler source missing swipe case")
            return
        }
        let swipeCaseEnd = source.range(of: "case \"", range: swipeCaseStart.upperBound..<source.endIndex)?.lowerBound
            ?? source.endIndex
        let swipeSegment = String(source[swipeCaseStart.upperBound..<swipeCaseEnd])
        XCTAssertTrue(
            swipeSegment.contains("wait:"),
            "ActionHandler swipe case must forward `wait:` into SwipeHandler.resolveAndSwipe"
        )
        XCTAssertTrue(
            swipeSegment.contains("parseWaitArgs"),
            "ActionHandler swipe case must build WaitArgs from the request body"
        )
    }

    /// Wave 3b.1: action=type with a query must gate through awaitPredicates
    /// before the coord-tap + PasteHelper flow. Without this, --wait-until on
    /// `simpilot action type --query SearchField --text foo --wait-until hittable`
    /// was silently dropped.
    func test_actionHandler_typeCase_forwardsWaitArgs() throws {
        let source = try loadActionHandlerSource()
        guard let typeCaseStart = source.range(of: "case \"type\":") else {
            XCTFail("ActionHandler source missing type case")
            return
        }
        let typeCaseEnd = source.range(of: "case \"", range: typeCaseStart.upperBound..<source.endIndex)?.lowerBound
            ?? source.endIndex
        let typeSegment = String(source[typeCaseStart.upperBound..<typeCaseEnd])
        XCTAssertTrue(
            typeSegment.contains("awaitPredicates"),
            "ActionHandler type case must call TapHandler.awaitPredicates to honor wait flags"
        )
        XCTAssertTrue(
            typeSegment.contains("parseWaitArgs"),
            "ActionHandler type case must build WaitArgs from the request body"
        )
        XCTAssertTrue(
            typeSegment.contains("waitTimeoutResponse"),
            "ActionHandler type case must return waitTimeoutResponse on gate timeout"
        )
    }

    /// SwipeHandler.resolveAndSwipe must accept a `wait:` parameter and run
    /// it through `TapHandler.awaitPredicates`. This is the only runtime hook
    /// between the swipe code path and ElementPoller — losing it reintroduces
    /// the Wave 3.1 iter 1 regression where swipe silently ignored wait_until.
    func test_swipeHandler_resolveAndSwipe_invokesAwaitPredicates() throws {
        let source = try loadSwipeHandlerSource()
        XCTAssertTrue(
            source.contains("wait: TapHandler.WaitArgs"),
            "SwipeHandler.resolveAndSwipe must accept `wait: TapHandler.WaitArgs`"
        )
        XCTAssertTrue(
            source.contains("TapHandler.awaitPredicates"),
            "SwipeHandler must invoke TapHandler.awaitPredicates to honor the wait gate"
        )
        XCTAssertTrue(
            source.contains("case .waitTimeout"),
            "SwipeHandler.Resolution must surface waitTimeout for the envelope translator"
        )
    }

    // MARK: - Helpers

    private func loadActionHandlerSource() throws -> String {
        return try loadHandlerSource(named: "ActionHandler.swift")
    }

    private func loadSwipeHandlerSource() throws -> String {
        return try loadHandlerSource(named: "SwipeHandler.swift")
    }

    private func loadHandlerSource(named fileName: String = "ActionHandler.swift") throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        var dir = thisFile.deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir
                .appendingPathComponent("Handlers")
                .appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            dir = dir.deletingLastPathComponent()
        }
        throw NSError(
            domain: "ActionHandlerTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not locate \(fileName) from #filePath"]
        )
    }
}
