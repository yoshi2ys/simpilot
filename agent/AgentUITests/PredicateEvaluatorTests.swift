import XCTest

final class PredicateEvaluatorTests: XCTestCase {

    // MARK: - Test fixtures

    private func makeElement(
        label: String = "Done",
        identifier: String = "saveButton",
        value: String = "",
        enabled: Bool = true,
        hittable: Bool? = nil
    ) -> DebugDescriptionParser.FoundElement {
        DebugDescriptionParser.FoundElement(
            type: "button",
            label: label,
            identifier: identifier,
            value: value,
            centerX: 100,
            centerY: 100,
            frame: (x: 0, y: 0, w: 200, h: 44),
            enabled: enabled,
            hittable: hittable
        )
    }

    // MARK: - Stateless predicates

    func test_exists_true_whenElementPresent() {
        XCTAssertTrue(PredicateEvaluator.matches(.exists, element: makeElement()))
    }

    func test_exists_false_whenNil() {
        XCTAssertFalse(PredicateEvaluator.matches(.exists, element: nil))
    }

    func test_notExists_true_whenNil() {
        XCTAssertTrue(PredicateEvaluator.matches(.notExists, element: nil))
    }

    func test_notExists_false_whenElementPresent() {
        XCTAssertFalse(PredicateEvaluator.matches(.notExists, element: makeElement()))
    }

    func test_enabled_followsElementFlag() {
        XCTAssertTrue(PredicateEvaluator.matches(.enabled, element: makeElement(enabled: true)))
        XCTAssertFalse(PredicateEvaluator.matches(.enabled, element: makeElement(enabled: false)))
        XCTAssertFalse(PredicateEvaluator.matches(.enabled, element: nil))
    }

    func test_hittable_requiresExplicitTrue() {
        XCTAssertTrue(PredicateEvaluator.matches(.hittable, element: makeElement(hittable: true)))
        XCTAssertFalse(PredicateEvaluator.matches(.hittable, element: makeElement(hittable: false)))
        // A fast-path element without a hittability check must not count as hittable;
        // callers that need this predicate must go through ElementPoller.
        XCTAssertFalse(PredicateEvaluator.matches(.hittable, element: makeElement(hittable: nil)))
        XCTAssertFalse(PredicateEvaluator.matches(.hittable, element: nil))
    }

    // MARK: - parseSimple

    func test_parseSimple_recognizesAllNoArgPredicates() {
        XCTAssertEqual(Predicate.parseSimple("exists"), .exists)
        XCTAssertEqual(Predicate.parseSimple("enabled"), .enabled)
        XCTAssertEqual(Predicate.parseSimple("hittable"), .hittable)
        XCTAssertEqual(Predicate.parseSimple("stable"), .stable)
        XCTAssertEqual(Predicate.parseSimple("not-exists"), .notExists)
        XCTAssertEqual(Predicate.parseSimple("notexists"), .notExists)
        XCTAssertEqual(Predicate.parseSimple("gone"), .notExists)
    }

    func test_parseSimple_ignoresCaseAndWhitespace() {
        XCTAssertEqual(Predicate.parseSimple("  HITTABLE  "), .hittable)
        XCTAssertEqual(Predicate.parseSimple("Stable"), .stable)
    }

    func test_parseSimple_rejectsUnknownAndArgPredicates() {
        XCTAssertNil(Predicate.parseSimple("label"))
        XCTAssertNil(Predicate.parseSimple("value"))
        XCTAssertNil(Predicate.parseSimple("bogus"))
    }

    // MARK: - StringMatcher.exact

    func test_exactMatcher_trimsWhitespaceButPreservesCaseAndInternalSpaces() {
        let matcher = try! parseMatcher("Done")
        XCTAssertTrue(matcher.matches("Done"))
        XCTAssertTrue(matcher.matches("  Done  "))
        XCTAssertFalse(matcher.matches("done"))       // case-sensitive
        XCTAssertFalse(matcher.matches("D one"))      // internal space significant
        XCTAssertFalse(matcher.matches(nil))
    }

    func test_exactMatcher_emptyExpectedMatchesEmptyObserved() {
        let matcher = try! parseMatcher("")
        XCTAssertTrue(matcher.matches(""))
        XCTAssertTrue(matcher.matches("   "))
        XCTAssertFalse(matcher.matches("x"))
    }

    // MARK: - StringMatcher.contains

    func test_containsMatcher_caseInsensitiveSubstring() {
        let matcher = try! parseMatcher("contains:items")
        XCTAssertTrue(matcher.matches("5 items"))
        XCTAssertTrue(matcher.matches("5 Items"))        // case-insensitive
        XCTAssertTrue(matcher.matches("ITEMS total"))
    }

    func test_containsMatcher_collapsesWhitespace() {
        let matcher = try! parseMatcher("contains:items")
        XCTAssertTrue(matcher.matches(" 5  items"))      // internal double space
        XCTAssertTrue(matcher.matches(" 5\titems "))     // tab as whitespace
    }

    func test_containsMatcher_handlesNBSP() {
        let matcher = try! parseMatcher("contains:42 %")
        // UI strings often use non-breaking space between a number and its unit.
        XCTAssertTrue(matcher.matches("42\u{00A0}%"))
        XCTAssertTrue(matcher.matches("42 %"))
    }

    func test_containsMatcher_rejectsMismatch() {
        let matcher = try! parseMatcher("contains:items")
        XCTAssertFalse(matcher.matches("5 widgets"))
        XCTAssertFalse(matcher.matches(nil))
    }

    func test_containsMatcher_emptyIsRejectedAtParse() {
        switch StringMatcher.parse("contains:") {
        case .failure(.emptyContains): break
        default: XCTFail("expected emptyContains parse error")
        }
        switch StringMatcher.parse("contains:   ") {
        case .failure(.emptyContains): break
        default: XCTFail("expected emptyContains after whitespace folding")
        }
    }

    // MARK: - StringMatcher.regex

    func test_regexMatcher_defaultsToCaseSensitive() {
        let matcher = try! parseMatcher(#"regex:^\d+ items?$"#)
        XCTAssertTrue(matcher.matches("5 items"))
        XCTAssertTrue(matcher.matches("1 item"))
        XCTAssertFalse(matcher.matches("5 Items"))       // uppercase I
        XCTAssertFalse(matcher.matches("5  items"))      // internal double space
    }

    func test_regexMatcher_acceptsInlineCaseInsensitiveFlag() {
        let matcher = try! parseMatcher(#"regex:(?i)^\d+ items?$"#)
        XCTAssertTrue(matcher.matches("5 Items"))
    }

    func test_regexMatcher_trimsObserved() {
        let matcher = try! parseMatcher(#"regex:^hello$"#)
        XCTAssertTrue(matcher.matches("  hello  "))
    }

    func test_regexMatcher_invalidPatternSurfacesError() {
        switch StringMatcher.parse("regex:[invalid") {
        case .failure(.invalidRegex(let pattern, _)):
            XCTAssertEqual(pattern, "[invalid")
        default:
            XCTFail("expected invalidRegex parse error")
        }
    }

    // MARK: - StringMatcher equality

    func test_regexEquality_comparesByPattern() {
        let a = try! parseMatcher(#"regex:^hi$"#)
        let b = try! parseMatcher(#"regex:^hi$"#)
        XCTAssertEqual(a, b, "Two regexes compiled from the same pattern must compare equal")
    }

    // MARK: - label / value predicate routing

    func test_labelPredicate_usesMatcher() {
        let pred = Predicate.label(try! parseMatcher("contains:gen"))
        let element = makeElement(label: "General")
        XCTAssertTrue(PredicateEvaluator.matches(pred, element: element))
    }

    func test_valuePredicate_usesMatcher() {
        let pred = Predicate.value(try! parseMatcher(#"regex:^\d+$"#))
        let element = makeElement(value: "42")
        XCTAssertTrue(PredicateEvaluator.matches(pred, element: element))
    }

    func test_valuePredicate_mismatchFails() {
        let pred = Predicate.value(try! parseMatcher("42"))
        XCTAssertFalse(PredicateEvaluator.matches(pred, element: makeElement(value: "")))
        XCTAssertFalse(PredicateEvaluator.matches(pred, element: makeElement(value: "43")))
        XCTAssertTrue(PredicateEvaluator.matches(pred, element: makeElement(value: "42")))
    }

    func test_valuePredicate_nilElementFails() {
        let pred = Predicate.value(try! parseMatcher(""))
        XCTAssertFalse(PredicateEvaluator.matches(pred, element: nil))
    }

    // MARK: - Helpers

    private func parseMatcher(_ raw: String) throws -> StringMatcher {
        switch StringMatcher.parse(raw) {
        case .success(let m): return m
        case .failure(let e):
            throw NSError(
                domain: "PredicateEvaluatorTests",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "StringMatcher.parse failed: \(e)"]
            )
        }
    }
}
