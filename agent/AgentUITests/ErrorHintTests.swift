import XCTest

/// SU2: every error envelope carries the repair for its code in `error.hint`,
/// separate from the message that describes the failure.
final class ErrorHintTests: XCTestCase {

    /// The body of an `HTTPResponseBuilder` response.
    private func errorObject(of response: Data) throws -> [String: Any] {
        let text = try XCTUnwrap(String(data: response, encoding: .utf8))
        let separator = try XCTUnwrap(text.range(of: "\r\n\r\n"))
        let body = Data(String(text[separator.upperBound...]).utf8)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        return try XCTUnwrap(json["error"] as? [String: Any])
    }

    // MARK: - The table

    /// A second copy of `table`'s keys, deliberately. Derived from the table it
    /// checks, this test could never fail; written out, it turns any deletion into
    /// a failure — which is the only way a hint disappears silently.
    private static let mustHaveHints = [
        "element_not_found", "invalid_query", "no_snapshot", "stale_alias",
        "alias_unsupported", "activate_failed", "launch_failed", "unsupported_platform",
        "wait_timeout", "element_still_exists", "assertion_failed", "alert_not_found",
        "objc_exception",
        "tap_failed", "swipe_failed", "drag_failed", "pinch_failed", "slider_failed",
        "screenshot_failed", "unauthorized", "not_found", "batch_failed",
        "invalid_command", "invalid_args", "invalid_regex", "paste_failed",
    ]

    func test_everyHighTrafficCodeHasAHint() {
        for code in Self.mustHaveHints {
            XCTAssertNotNil(ErrorHint.standard(for: code), "\(code) lost its hint")
        }
    }

    func test_everyHintIsUsableProse() {
        for (code, hint) in ErrorHint.table {
            XCTAssertFalse(hint.isEmpty, "\(code) has an empty hint")
            XCTAssertEqual(hint, hint.trimmingCharacters(in: .whitespacesAndNewlines), "\(code)")
        }
    }

    /// `invalid_request` is the most-raised code in the agent and deliberately has
    /// no hint: each site names the field it rejected, and a generic "check the
    /// arguments" would be a line the caller re-reads on every validation error.
    func test_codesWithNoUniformRepairHaveNoHint() {
        XCTAssertNil(ErrorHint.standard(for: "invalid_request"))
        XCTAssertNil(ErrorHint.standard(for: "some_code_that_does_not_exist"))
    }

    /// The partition is enforced, not documented: every code the agent actually
    /// raises must be in `table` or in `deliberatelyWithoutHint`.
    ///
    /// Without this, a new handler spelling a new code gets no hint and nothing
    /// notices — the table's keys are strings with no symbol tying them to a raise
    /// site, so a test that walks the table alone proves only that its own entries
    /// exist. Reading the sources is the same last-resort technique the wiring
    /// guards in `ActionHandlerTests` use, for the same reason: the property is
    /// about code that a pure-logic suite cannot otherwise reach.
    func test_everyCodeRaisedInTheAgentHasADecision() throws {
        let raised = try codesRaisedInSources()
        XCTAssertGreaterThan(raised.count, 30, "the scan found almost nothing — it is probably broken")

        let decided = Set(ErrorHint.table.keys).union(ErrorHint.deliberatelyWithoutHint)
        XCTAssertEqual(
            raised.subtracting(decided).sorted(), [],
            "these codes are raised with no hint decision — add them to ErrorHint.table, "
                + "or to deliberatelyWithoutHint if the repair only lives in the message"
        )
        XCTAssertEqual(
            decided.subtracting(raised).sorted(), [],
            "these codes are decided but never raised — dead entries"
        )
    }

    /// The scan above reads literals, so a code assembled at runtime
    /// (`code: shouldExist ? "a" : "b"`) would slip past it — `wait`'s
    /// `element_still_exists` did exactly that. Only the handful of files that
    /// *forward* someone else's code may pass `code:` a variable; anywhere else it
    /// must be written out where it is raised.
    func test_noHandlerAssemblesAnErrorCodeAtRuntime() throws {
        let forwarders: Set<String> = [
            "ActionHandler.swift",   // screenshotFailure(code:message:)
            "BatchHandler.swift",    // failureResult(code:message:) and its callers
            "HTTPResponse.swift",    // error(_:code:) → errorObject(code:message:hint:)
            "HTTPServer.swift",      // HTTPParser's .reject(status:code:message:)
        ]
        XCTAssertEqual(try filesPassingANonLiteralCode().subtracting(forwarders).sorted(), [])
    }

    /// Files with a `code:` argument that is not a string literal.
    private func filesPassingANonLiteralCode() throws -> Set<String> {
        try scanSources(pattern: "code: [a-z][A-Za-z0-9_.]*") { _, file in file }
    }

    /// Every `code: "…"` literal under the agent's source directories.
    private func codesRaisedInSources() throws -> Set<String> {
        try scanSources(pattern: "code: \"([a-z_]+)\"") { capture, _ in capture }
    }

    /// Walks `Handlers` / `Core` / `Server` and folds every regex match into a set.
    /// `pick` receives capture group 1 (empty when the pattern has none) and the
    /// file name, and returns what to collect.
    private func scanSources(
        pattern: String,
        pick: (String, String) -> String
    ) throws -> Set<String> {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let regex = try NSRegularExpression(pattern: pattern)
        var found: Set<String> = []
        for directory in ["Handlers", "Core", "Server"] {
            let path = root.appendingPathComponent(directory)
            for file in try FileManager.default.contentsOfDirectory(atPath: path.path)
            where file.hasSuffix(".swift") {
                let source = try String(contentsOf: path.appendingPathComponent(file), encoding: .utf8)
                let whole = NSRange(source.startIndex..., in: source)
                for match in regex.matches(in: source, range: whole) {
                    let capture = match.numberOfRanges > 1
                        ? Range(match.range(at: 1), in: source).map { String(source[$0]) } ?? ""
                        : ""
                    found.insert(pick(capture, file))
                }
            }
        }
        return found
    }

    /// The one advertised conflict: the standard advice for `element_not_found` is
    /// to reach for `scroll-to`, which is nonsense coming from `scroll-to` itself.
    func test_scrollToOverridesTheElementNotFoundHint() throws {
        XCTAssertTrue(
            (ErrorHint.standard(for: "element_not_found") ?? "").contains("scroll-to"),
            "the override below exists because of this"
        )
        let error = try errorObject(
            of: ScrollToHandler.notFound(query: "Privacy", direction: "down", maxSwipes: 3)
        )
        let hint = try XCTUnwrap(error["hint"] as? String)
        XCTAssertNotEqual(hint, ErrorHint.standard(for: "element_not_found"))
        XCTAssertTrue(hint.contains("--max-swipes"), hint)
        XCTAssertEqual(error["swipes"] as? Int, 3, "the diagnostic fields still ride in extra")
    }

    // MARK: - The envelope

    func test_errorEnvelopeCarriesTheStandardHint() throws {
        let error = try errorObject(
            of: HTTPResponseBuilder.error("no such element", code: "element_not_found")
        )
        XCTAssertEqual(error["code"] as? String, "element_not_found")
        XCTAssertEqual(error["message"] as? String, "no such element")
        XCTAssertEqual(error["hint"] as? String, ErrorHint.standard(for: "element_not_found"))
    }

    func test_aCodeWithNoStandardHintOmitsTheKeyEntirely() throws {
        let error = try errorObject(
            of: HTTPResponseBuilder.error("Missing 'x'", code: "invalid_request")
        )
        XCTAssertNil(error["hint"], "an absent hint is an absent key, not an empty string or null")
    }

    func test_anExplicitHintWinsOverTheTable() throws {
        let error = try errorObject(
            of: HTTPResponseBuilder.error(
                "Element not found after 3 swipes",
                code: "element_not_found",
                hint: "Try a larger --max-swipes."
            )
        )
        XCTAssertEqual(error["hint"] as? String, "Try a larger --max-swipes.")
    }

    /// `extra:` owns the diagnostic fields a handler adds (`swipes`, `query`), not
    /// the three the named arguments own.
    func test_extraCannotOverwriteCodeMessageOrHint() throws {
        let error = try errorObject(
            of: HTTPResponseBuilder.error(
                "real message",
                code: "stale_alias",
                extra: ["code": "spoofed", "message": "spoofed", "hint": "spoofed", "swipes": 3]
            )
        )
        XCTAssertEqual(error["code"] as? String, "stale_alias")
        XCTAssertEqual(error["message"] as? String, "real message")
        XCTAssertEqual(error["hint"] as? String, ErrorHint.standard(for: "stale_alias"))
        XCTAssertEqual(error["swipes"] as? Int, 3)
    }

    // MARK: - Sub-results

    /// A `/batch` sub-command's failure is the caller's only account of what went
    /// wrong inside a 200, so it carries the same hint the standalone error would.
    func test_batchSubResultCarriesTheSameHint() throws {
        let result = BatchHandler.failureResult(code: "element_not_found", message: "nope")
        let error = try XCTUnwrap(result["error"] as? [String: Any])
        XCTAssertEqual(error["hint"] as? String, ErrorHint.standard(for: "element_not_found"))
    }

    /// `action`'s screenshot leg keeps its own `{error, code}` keys — renaming them
    /// would break every caller reading `data.screenshot.error` — but not its own
    /// idea of the repair.
    func test_actionScreenshotSlotCarriesTheSameHint() {
        let slot = ActionHandler.screenshotFailure(code: "alias_unsupported", message: "nope")
        XCTAssertEqual(slot["error"] as? String, "nope")
        XCTAssertEqual(slot["code"] as? String, "alias_unsupported")
        XCTAssertEqual(slot["hint"] as? String, ErrorHint.standard(for: "alias_unsupported"))

        let noHint = ActionHandler.screenshotFailure(code: "invalid_request", message: "bad scale")
        XCTAssertNil(noHint["hint"])
    }

    /// The alias messages state the condition only; the repair moved to the hint,
    /// so an agent does not read the same sentence twice.
    func test_aliasMessagesDoNotRepeatTheirHint() throws {
        let stale = try errorObject(of: AliasResponse.error(.stale("@e3 now points at a different element")))
        XCTAssertEqual(stale["message"] as? String, "@e3 now points at a different element")
        XCTAssertEqual(stale["hint"] as? String, ErrorHint.standard(for: "stale_alias"))

        let none = try errorObject(of: AliasResponse.error(.noSnapshot))
        let message = try XCTUnwrap(none["message"] as? String)
        XCTAssertFalse(
            message.contains("--format outline"),
            "the repair belongs in the hint, not in both: \(message)"
        )
        XCTAssertEqual(none["hint"] as? String, ErrorHint.standard(for: "no_snapshot"))
    }
}
