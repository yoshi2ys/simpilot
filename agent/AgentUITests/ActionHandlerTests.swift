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
    //
    // These read the handler source rather than exercising it. They are a last
    // resort, kept only where the behavior needs a live `XCUIApplication` that
    // this pure-logic suite has no way to stand up. Anything reachable through a
    // pure function is tested for real in the envelope section below — prefer
    // that when adding coverage, and delete the structural guard it replaces.

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
        // Tap case previously called DebugDescriptionParser.findElement directly,
        // and so did the type case until A15 moved it into TypeHandler.resolveAndType.
        // ActionHandler now resolves nothing itself: any occurrence is a regression.
        let findElementOccurrences = source.components(separatedBy: "DebugDescriptionParser.findElement").count - 1
        XCTAssertEqual(
            findElementOccurrences,
            0,
            "ActionHandler must not call DebugDescriptionParser.findElement directly — resolution belongs to the shared helpers."
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

    // MARK: - Failure envelopes (behavior, not source text)

    /// Decode a handler's raw HTTP response into the two things a client can
    /// actually observe: the status line and the JSON envelope.
    private func decodeEnvelope(_ data: Data) throws -> (status: Int, json: [String: Any]) {
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let statusLine = try XCTUnwrap(text.components(separatedBy: "\r\n").first)
        let status = try XCTUnwrap(Int(statusLine.components(separatedBy: " ")[1]))
        let separator = try XCTUnwrap(text.range(of: "\r\n\r\n"))
        let body = Data(String(text[separator.upperBound...]).utf8)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        return (status, json)
    }

    private func error(_ json: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(json["error"] as? [String: Any])
    }

    func test_tapEnvelope_elementNotFound() throws {
        let (status, json) = try decodeEnvelope(
            TapHandler.responseData(from: .elementNotFound(query: "General"))
        )
        XCTAssertEqual(status, 400)
        XCTAssertEqual(json["success"] as? Bool, false)
        XCTAssertEqual(try error(json)["code"] as? String, "element_not_found")
        XCTAssertEqual(try error(json)["message"] as? String, "Element not found for query: General")
    }

    func test_tapEnvelope_waitTimeout_carriesDiagnostics() throws {
        let (status, json) = try decodeEnvelope(TapHandler.responseData(from: .waitTimeout(
            query: "Save",
            failedPredicates: ["hittable"],
            lastState: ["type": "button"],
            timeoutMs: 3000
        )))
        XCTAssertEqual(status, 408)
        let err = try error(json)
        XCTAssertEqual(err["code"] as? String, "wait_timeout")
        XCTAssertEqual(err["query"] as? String, "Save")
        XCTAssertEqual(err["failed_predicates"] as? [String], ["hittable"])
        XCTAssertEqual(err["timeout_ms"] as? Int, 3000)
        XCTAssertEqual((err["last_state"] as? [String: Any])?["type"] as? String, "button")
    }

    func test_tapEnvelope_remainingFailureCodes() throws {
        let cases: [(TapHandler.Resolution, String)] = [
            (.noElementToTap(query: "X"), "no_element_to_tap"),
            (.tapFailed(query: "X", reason: "boom"), "tap_failed")
        ]
        for (resolution, expectedCode) in cases {
            let (status, json) = try decodeEnvelope(TapHandler.responseData(from: resolution))
            XCTAssertEqual(status, 400)
            XCTAssertEqual(try error(json)["code"] as? String, expectedCode)
        }
    }

    func test_tapEnvelope_successCarriesTheElement() throws {
        let (status, json) = try decodeEnvelope(
            TapHandler.responseData(from: .success(element: ["type": "button", "label": "OK"]))
        )
        XCTAssertEqual(status, 200)
        XCTAssertEqual(json["success"] as? Bool, true)
        let data = try XCTUnwrap(json["data"] as? [String: Any])
        XCTAssertEqual((data["element"] as? [String: Any])?["label"] as? String, "OK")
    }

    /// A15's real contract: `/type` and `/action type` must produce the *same
    /// bytes* as `/tap` for the same failure. Comparing the envelopes directly
    /// catches drift that a `source.contains(...)` scan only approximates.
    func test_typeFailureEnvelope_isByteIdenticalToTap() {
        XCTAssertEqual(
            TypeHandler.failureResponse(for: .elementNotFound(query: "Search")),
            TapHandler.responseData(from: .elementNotFound(query: "Search"))
        )
        XCTAssertEqual(
            TypeHandler.failureResponse(for: .waitTimeout(
                query: "Search", failedPredicates: ["exists"],
                lastState: nil, timeoutMs: 1500
            )),
            TapHandler.waitTimeoutResponse(
                query: "Search", failedPredicates: ["exists"],
                lastState: nil, timeoutMs: 1500
            )
        )
    }

    func test_typeFailureEnvelope_inputFailurePassesThroughVerbatim() {
        // PasteHelper already built a full envelope; re-wrapping it would lose
        // its specific code (`paste_failed` / `unsupported_platform`).
        let pasteError = HTTPResponseBuilder.error("Paste menu not found.", code: "paste_failed")
        XCTAssertEqual(TypeHandler.failureResponse(for: .inputFailed(pasteError)), pasteError)
    }

    func test_notFoundMessageIsTheOneWording() {
        XCTAssertEqual(
            ElementResolver.notFoundMessage(query: "General"),
            "Element not found for query: General"
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

    // MARK: - AlertHandler error contract (Wave 3b fix #2)

    func test_alertHandler_notFound_returnsErrorCode() throws {
        let source = try loadHandlerSource(named: "AlertHandler.swift")
        let notFoundOccurrences = source.components(separatedBy: "alert_not_found").count - 1
        XCTAssertGreaterThanOrEqual(
            notFoundOccurrences, 2,
            "AlertHandler must return error code 'alert_not_found' for both timeout and immediate not-found paths"
        )
        XCTAssertFalse(
            source.contains("\"found\": false"),
            "AlertHandler must not return success envelope with found=false — use HTTPResponseBuilder.error"
        )
    }

    func test_alertHandler_noButtons_returnsErrorCode() throws {
        let source = try loadHandlerSource(named: "AlertHandler.swift")
        XCTAssertTrue(
            source.contains("alert_no_buttons"),
            "AlertHandler must return error code 'alert_no_buttons' when alert has no buttons"
        )
        XCTAssertFalse(
            source.contains("\"Alert found but has no buttons\""),
            "AlertHandler must not return success envelope for no-buttons case"
        )
    }

    func test_alertHandler_usesErrorBuilderForFailures() throws {
        let source = try loadHandlerSource(named: "AlertHandler.swift")
        let errorCalls = source.components(separatedBy: "HTTPResponseBuilder.error").count - 1
        XCTAssertGreaterThanOrEqual(
            errorCalls, 3,
            "AlertHandler must use HTTPResponseBuilder.error for: invalid_request, alert_not_found (×2), alert_no_buttons"
        )
    }

    // MARK: - action=type wait gate behavior backstop (Wave 3b fix #3)

    func test_actionHandler_typeCase_awaitPredicatesIsEffective() {
        let body: [String: Any] = [
            "action": "type",
            "query": "SearchField",
            "text": "hello",
            "wait_until": ["hittable"],
            "timeout_ms": 3000
        ]
        let args = TapHandler.parseWaitArgs(from: body)
        XCTAssertTrue(
            TapHandler.needsPolling(wait: args),
            "parseWaitArgs → needsPolling must be true when wait_until is set (action=type gate)"
        )
        let effective = TapHandler.effectivePredicates(wait: args)
        XCTAssertEqual(
            effective.map { $0.name }, ["hittable"],
            "effectivePredicates must pass through explicit predicates from action=type body"
        )
    }

    // MARK: - Element screenshot wire contract (Wave 4a)

    /// ScreenshotHandler must use `ElementResolver.resolve` to handle the
    /// `element` query parameter and wrap `element.screenshot()` with
    /// `catchObjCException` to catch NSException from detached/zero-frame elements.
    func test_screenshotHandler_elementParam_usesResolverAndObjCGuard() throws {
        let source = try loadHandlerSource(named: "ScreenshotHandler.swift")
        XCTAssertTrue(
            source.contains("request.queryParams[\"element\"]"),
            "ScreenshotHandler must read the 'element' query parameter"
        )
        XCTAssertTrue(
            source.contains("ElementResolver.resolve"),
            "ScreenshotHandler must use ElementResolver.resolve for element screenshot"
        )
        XCTAssertTrue(
            source.contains("element.screenshot()"),
            "ScreenshotHandler must call element.screenshot() for element-level capture"
        )
        XCTAssertTrue(
            source.contains("catchObjCException"),
            "ScreenshotHandler must wrap element.screenshot() with catchObjCException"
        )
    }

    /// ScreenshotHandler must return distinct error codes: `element_not_found`
    /// for resolver failures vs `screenshot_failed` for ObjC exceptions during capture.
    func test_screenshotHandler_errorCodeSeparation() throws {
        let source = try loadHandlerSource(named: "ScreenshotHandler.swift")
        XCTAssertTrue(
            source.contains("\"element_not_found\""),
            "ScreenshotHandler must return 'element_not_found' when ElementResolver fails"
        )
        XCTAssertTrue(
            source.contains("\"screenshot_failed\""),
            "ScreenshotHandler must return 'screenshot_failed' when element.screenshot() throws NSException"
        )
    }

    /// ScreenshotHandler must fall back to XCUIScreen.main when no element param.
    func test_screenshotHandler_noElement_usesFullScreen() throws {
        let source = try loadHandlerSource(named: "ScreenshotHandler.swift")
        XCTAssertTrue(
            source.contains("XCUIScreen.main.screenshot()"),
            "ScreenshotHandler must use XCUIScreen.main.screenshot() when no element param"
        )
    }

    /// ActionHandler must read `screenshot_element` from the JSON body and
    /// route it through ElementResolver + catchObjCException for element-level
    /// screenshot, while preserving action_result on failure (soft-fail).
    func test_actionHandler_screenshotElement_softFailShape() throws {
        let source = try loadActionHandlerSource()

        // 1. Reads the field
        XCTAssertTrue(
            source.contains("\"screenshot_element\""),
            "ActionHandler must read 'screenshot_element' from the JSON body"
        )

        // 2. Uses ElementResolver
        XCTAssertTrue(
            source.contains("ElementResolver.resolve(query: screenshotElement"),
            "ActionHandler must use ElementResolver.resolve for screenshot_element"
        )

        // 3. Wraps with catchObjCException
        XCTAssertTrue(
            source.contains("catchObjCException"),
            "ActionHandler must wrap element.screenshot() with catchObjCException"
        )

        // 4. Soft-fail: screenshot error goes to responseData, NOT early return
        // The screenshot section must set responseData["screenshot"] on error
        // and must NOT return before the elements section.
        let screenshotSection = extractSection(
            from: source,
            startMarker: "// 3. Screenshot",
            endMarker: "// 4. Elements"
        )
        XCTAssertNotNil(screenshotSection, "ActionHandler must have labeled screenshot and elements sections")
        if let section = screenshotSection {
            XCTAssertTrue(
                section.contains("responseData[\"screenshot\"]"),
                "ActionHandler screenshot section must write errors to responseData[\"screenshot\"]"
            )
            XCTAssertTrue(
                section.contains("fullPng = nil"),
                "ActionHandler must set fullPng = nil on element screenshot failure (soft-fail)"
            )
            // No early return in the screenshot section — elements must still run
            let returnCount = section.components(separatedBy: "return ").count - 1
            XCTAssertEqual(
                returnCount, 0,
                "ActionHandler screenshot section must NOT return early — action_result and elements must be preserved"
            )
            // 5. Error objects must include structured code field
            XCTAssertTrue(
                section.contains("\"code\": \"element_not_found\""),
                "ActionHandler screenshot error for resolver failure must include code: element_not_found"
            )
            XCTAssertTrue(
                section.contains("\"code\": \"screenshot_failed\""),
                "ActionHandler screenshot error for ObjC exception must include code: screenshot_failed"
            )
        }
    }

    /// ActionHandler must still use XCUIScreen.main when screenshot_element is absent.
    func test_actionHandler_noScreenshotElement_usesFullScreen() throws {
        let source = try loadActionHandlerSource()
        // The screenshot section has the full-screen fallback
        let screenshotSection = extractSection(
            from: source,
            startMarker: "// 3. Screenshot",
            endMarker: "// 4. Elements"
        )
        XCTAssertNotNil(screenshotSection)
        if let section = screenshotSection {
            XCTAssertTrue(
                section.contains("XCUIScreen.main.screenshot()"),
                "ActionHandler must use XCUIScreen.main.screenshot() when screenshot_element is absent"
            )
        }
    }

    // MARK: - ScreenshotHandler.parseScale (A23: no silent scale coercion)

    func test_parseScale_native() {
        XCTAssertEqual(ScreenshotHandler.parseScale("native"), .native)
    }

    func test_parseScale_positiveFactor() {
        XCTAssertEqual(ScreenshotHandler.parseScale("2"), .factor(2))
        XCTAssertEqual(ScreenshotHandler.parseScale("0.5"), .factor(0.5))
    }

    func test_parseScale_zeroNegativeNonNumeric_areInvalid() {
        // Previously "0"/"-1" silently returned native pixels while reporting the
        // bogus factor, and "abc" silently coerced to 1.0.
        XCTAssertEqual(ScreenshotHandler.parseScale("0"), .invalid)
        XCTAssertEqual(ScreenshotHandler.parseScale("-1"), .invalid)
        XCTAssertEqual(ScreenshotHandler.parseScale("abc"), .invalid)
        XCTAssertEqual(ScreenshotHandler.parseScale(""), .invalid)
    }

    /// ActionHandler's inline screenshot shares this mapping so a bogus scale is
    /// rejected there too, not silently coerced to 1.0 (A23).
    func test_scaleSpec_fromStringDoubleAndAbsent() {
        XCTAssertEqual(ScreenshotHandler.scaleSpec(from: "native"), .native)
        XCTAssertEqual(ScreenshotHandler.scaleSpec(from: "2"), .factor(2))
        XCTAssertEqual(ScreenshotHandler.scaleSpec(from: "0"), .invalid)
        XCTAssertEqual(ScreenshotHandler.scaleSpec(from: "abc"), .invalid)
        XCTAssertEqual(ScreenshotHandler.scaleSpec(from: 2.0), .factor(2.0))
        XCTAssertEqual(ScreenshotHandler.scaleSpec(from: 0.0), .invalid)
        XCTAssertEqual(ScreenshotHandler.scaleSpec(from: -1.0), .invalid)
        // Absent scale keeps the historical 1.0 default.
        XCTAssertEqual(ScreenshotHandler.scaleSpec(from: nil), .factor(1.0))
    }

    // MARK: - Helpers

    private func extractSection(from source: String, startMarker: String, endMarker: String) -> String? {
        guard let startRange = source.range(of: startMarker) else { return nil }
        let endPos = source.range(of: endMarker, range: startRange.upperBound..<source.endIndex)?.lowerBound
            ?? source.endIndex
        return String(source[startRange.lowerBound..<endPos])
    }

    private func loadActionHandlerSource() throws -> String {
        return try loadHandlerSource(named: "ActionHandler.swift")
    }

    private func loadSwipeHandlerSource() throws -> String {
        return try loadHandlerSource(named: "SwipeHandler.swift")
    }

    private func loadHandlerSource(named fileName: String) throws -> String {
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
