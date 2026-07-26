import XCTest

/// SU4: repeating lists are detected from the parsed tree, and `@rN` / `@lMrN`
/// address their rows.
///
/// The detector is pure — it consumes `DebugDescriptionParser.parseLines` output —
/// so every rule is exercised against real captures (`Fixtures/*.txt`) plus
/// synthetic trees for the shapes that must *not* be read as lists. The wiring
/// checks at the end scan handler sources for the same reason `ActionHandlerTests`
/// does: which commands refuse a positional query is a property of code that no
/// pure-logic test can otherwise reach without a live simulator.
final class ListClusterTests: XCTestCase {

    private static let fixturesDirectory: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }()

    private func fixture(_ name: String) throws -> String {
        try String(contentsOf: Self.fixturesDirectory.appendingPathComponent(name), encoding: .utf8)
    }

    private func lists(inFixture name: String) throws -> [ListCluster] {
        ListClusterDetector.detect(in: parsed(try fixture(name)))
    }

    private func parsed(_ text: String) -> [DebugDescriptionParser.ParsedElement] {
        DebugDescriptionParser.parseLines(text)
    }

    /// A tree with a full-screen window and `rows` cells under one container.
    /// `line` builds each row so a test can vary one dimension at a time.
    private func tree(_ rows: [String]) -> String {
        var text = " →Application, 0x1, pid: 1, label: 'App'\n"
        text += "    Window (Main), 0x2, {{0.0, 0.0}, {402.0, 874.0}}\n"
        text += "      Other, 0x3, {{0.0, 0.0}, {402.0, 874.0}}\n"
        for row in rows { text += "        \(row)\n" }
        return text
    }

    private func cell(_ index: Int, y: Double, x: Double = 16, w: Double = 370, h: Double = 52) -> String {
        "Cell, 0x1\(index), {{\(x), \(y)}, {\(w), \(h)}}, label: 'row\(index)'"
    }

    // MARK: - Selector syntax

    func testRowSelectorSyntax() {
        XCTAssertEqual(RowSelector.parse("@r3"), RowSelector(list: nil, row: 3))
        XCTAssertEqual(RowSelector.parse("@l2r3"), RowSelector(list: 2, row: 3))
        XCTAssertEqual(RowSelector.parse(" @l12r34 "), RowSelector(list: 12, row: 34))
        XCTAssertEqual(RowSelector.parse("@r3")?.text, "@r3")
        XCTAssertEqual(RowSelector.parse("@l2r3")?.text, "@l2r3")
    }

    /// Everything that is not exactly the two shapes stays an ordinary query — `@`
    /// starts plenty of real labels, and the halves must not resolve to a guess.
    func testNonRowQueriesAreNotClaimed() {
        for query in [
            "@r", "@r0", "@l2", "@l2r", "@lr3", "@l0r1", "@r3x", "@3", "r3", "@e3",
            "@rowsFollowing", "", "General", "@r 3", "cell:@r3",
        ] {
            XCTAssertNil(RowSelector.parse(query), "\(query) must not be a row selector")
        }
    }

    /// `@eN` and `@rN` share one question — "is this query positional at all" — so
    /// the refusals cannot close on one form and leave the other open.
    func testPositionalKinds() {
        XCTAssertEqual(PositionalQuery.kind(of: "@e9"), .alias)
        XCTAssertEqual(PositionalQuery.kind(of: "@r9"), .row)
        XCTAssertEqual(PositionalQuery.kind(of: "@l1r9"), .row)
        XCTAssertNil(PositionalQuery.kind(of: "General"))
        XCTAssertNil(PositionalQuery.kind(of: "#chevron"))
        XCTAssertNil(PositionalQuery.kind(of: nil))
        // The documented escape hatch, for an app that really labels a row `@r3`.
        XCTAssertNil(PositionalQuery.kind(of: "cell:@r3"))
    }

    // MARK: - Detection on real captures

    /// The Settings root: one list of 8 rows. The Apple Account row above it is a
    /// `Cell` of the same width under the same container, but 90.3pt tall against
    /// 52 — a row of a different size is not a row of this list.
    func testSettingsRootHasOneListOfEightRows() throws {
        let lists = try lists(inFixture: "settings_root.txt")
        XCTAssertEqual(lists.count, 1)
        XCTAssertEqual(lists[0].type, "cell")
        XCTAssertEqual(lists[0].rows.count, 8)
        XCTAssertEqual(lists[0].rows.map { $0.element.frame.h }, Array(repeating: 52.0, count: 8))
        XCTAssertEqual(lists[0].rows.first?.element.frame.y, 293.3)
    }

    /// The modal capture carries two lists: the sheet's own and the screen behind
    /// it. Both are reported — deciding which one the caller meant is not the
    /// detector's job, and a bare `@rN` is refused as ambiguous rather than guessed.
    ///
    /// `@l1r1` is `Region, United States`, the row a lone-row-above-a-group run used
    /// to swallow: this capture is where that bug shows on real data, and the first
    /// row of the visible list is exactly the row a caller reaches for first.
    func testModalCaptureReportsBothLists() throws {
        let lists = try lists(inFixture: "language_sheet_modal.txt")
        XCTAssertEqual(lists.map { $0.rows.count }, [7, 11])
        XCTAssertEqual(lists[0].rows.first?.element.label, "Region, United States")
    }

    /// The same capture exposes 53 cells of that second list, 42 of which sit below
    /// a screen 874pt tall. Numbering those in would hand out `@r30` addresses whose
    /// coordinate is off screen, where a tap lands nowhere and reports success.
    func testRowsBelowTheScreenAreNotNumbered() throws {
        let lists = try lists(inFixture: "language_sheet_modal.txt")
        let rows = lists[1].rows
        XCTAssertEqual(rows.count, 11)
        for row in rows {
            XCTAssertLessThanOrEqual(row.element.frame.y + row.element.frame.h / 2, 874.0)
        }
    }

    /// Rows carry their position in the actionable list, which is what lets the
    /// outline header point at the `@eN` line the list starts on.
    func testRowsKnowTheirAliasPosition() throws {
        let lists = try lists(inFixture: "settings_root.txt")
        let first = try XCTUnwrap(lists[0].rows.first)
        let elements = DebugDescriptionParser.parseActionableList(
            fromRawDescription: try fixture("settings_root.txt")
        )
        XCTAssertEqual(
            elements[first.actionableIndex]["type"] as? String, first.element.type
        )
        XCTAssertEqual(
            (elements[first.actionableIndex]["frame"] as? [String: Any])?["y"] as? Double,
            first.element.frame.y
        )
    }

    // MARK: - What must not be read as a list

    func testTwoRowsAreNotAList() {
        let text = tree([cell(1, y: 100), cell(2, y: 152)])
        XCTAssertEqual(ListClusterDetector.detect(in: parsed(text)).count, 0)
    }

    func testThreeRowsAre() {
        let text = tree([cell(1, y: 100), cell(2, y: 152), cell(3, y: 204)])
        XCTAssertEqual(ListClusterDetector.detect(in: parsed(text)).first?.rows.count, 3)
    }

    /// A grid is not a list: its cells share a y and differ in x, so nothing about
    /// "the Nth row" is well defined. Requiring a shared left edge keeps them out.
    func testAGridIsNotAList() {
        let text = tree([
            cell(1, y: 100, x: 16, w: 120), cell(2, y: 100, x: 140, w: 120), cell(3, y: 100, x: 264, w: 120),
            cell(4, y: 224, x: 16, w: 120), cell(5, y: 224, x: 140, w: 120), cell(6, y: 224, x: 264, w: 120),
        ])
        XCTAssertEqual(ListClusterDetector.detect(in: parsed(text)).count, 0)
    }

    /// Pitch is compared against the run's first gap, not the previous one.
    /// Comparing neighbours lets a point of slack accumulate per row, so a stack of
    /// unevenly spaced things would pass the whole way down.
    func testDriftingPitchIsNotAList() {
        let text = tree([
            cell(1, y: 100), cell(2, y: 152), cell(3, y: 205.5), cell(4, y: 261), cell(5, y: 318),
        ])
        XCTAssertEqual(ListClusterDetector.detect(in: parsed(text)).count, 0)
    }

    /// A tenth of a point of layout rounding must not split a list — real frames
    /// come out of debugDescription rounded (`52.0`, `73.7`).
    func testATenthOfAPointDoesNotSplitAList() {
        let text = tree([cell(1, y: 100), cell(2, y: 152.1), cell(3, y: 204.0), cell(4, y: 256.2)])
        XCTAssertEqual(ListClusterDetector.detect(in: parsed(text)).first?.rows.count, 4)
    }

    /// The bug this pins: a lone row of the same size above a group — an ordinary
    /// one-row section — used to pair with the group's first row, and that pair was
    /// then discarded for being too short, taking the group's first row with it. `@r1`
    /// silently named the group's *second* row.
    func testALoneRowAboveAGroupDoesNotSwallowItsFirstRow() {
        let text = tree([
            cell(1, y: 100),
            cell(2, y: 200), cell(3, y: 244), cell(4, y: 288), cell(5, y: 332),
        ])
        let lists = ListClusterDetector.detect(in: parsed(text))
        XCTAssertEqual(lists.count, 1)
        XCTAssertEqual(lists.first?.rows.map { $0.element.frame.y }, [200, 244, 288, 332])
    }

    /// The same shape one row shorter: the group is three rows, so losing its first
    /// used to erase the list entirely.
    func testALoneRowAboveAThreeRowGroupStillLeavesAList() {
        let text = tree([cell(1, y: 100), cell(2, y: 200), cell(3, y: 244), cell(4, y: 288)])
        XCTAssertEqual(
            ListClusterDetector.detect(in: parsed(text)).first?.rows.map { $0.element.frame.y },
            [200, 244, 288]
        )
    }

    /// Shape is compared against the run's first row, not the previous one, for the
    /// same reason as the pitch: 0.9pt per row passes every neighbour comparison and
    /// gives a "list" whose rows differ by 8pt.
    func testWidthDriftingAgainstTheFirstRowIsNotAList() {
        var rows: [String] = []
        for index in 0..<10 {
            rows.append(cell(index + 1, y: 100 + Double(index) * 52, w: 370 + Double(index) * 0.9))
        }
        let lists = ListClusterDetector.detect(in: parsed(tree(rows)))
        for list in lists {
            let widths = list.rows.map { $0.element.frame.w }
            XCTAssertLessThanOrEqual(
                (widths.max() ?? 0) - (widths.min() ?? 0), ListClusterDetector.tolerance,
                "a run must not accumulate shape drift"
            )
        }
    }

    /// A gap wider than the pitch splits the run — that is what separates the two
    /// sections of one table, and the two lists of the modal capture.
    func testASectionGapSplitsTheRun() {
        let text = tree([
            cell(1, y: 100), cell(2, y: 152), cell(3, y: 204),
            cell(4, y: 340), cell(5, y: 392), cell(6, y: 444),
        ])
        XCTAssertEqual(ListClusterDetector.detect(in: parsed(text)).map { $0.rows.count }, [3, 3])
    }

    /// Rows of different containers do not merge, even at the same depth: their y
    /// values would interleave into one evenly-spaced run that never existed.
    func testSiblingsOfDifferentContainersDoNotMerge() {
        var text = " →Application, 0x1, pid: 1, label: 'App'\n"
        text += "    Window (Main), 0x2, {{0.0, 0.0}, {402.0, 874.0}}\n"
        text += "      Other, 0x3, {{0.0, 0.0}, {402.0, 400.0}}\n"
        for (index, y) in [100.0, 204.0].enumerated() {
            text += "        \(cell(index + 1, y: y))\n"
        }
        text += "      Other, 0x9, {{0.0, 400.0}, {402.0, 400.0}}\n"
        for (index, y) in [152.0, 256.0].enumerated() {
            text += "        \(cell(index + 5, y: y))\n"
        }
        XCTAssertEqual(ListClusterDetector.detect(in: parsed(text)).count, 0)
    }

    /// A tree with no window has no viewport, so nothing can be called visible and
    /// no list is reported — rather than every off-screen row being numbered in.
    func testNoViewportMeansNoLists() {
        var text = " →Application, 0x1, pid: 1, label: 'App'\n"
        for index in 1...4 { text += "    \(cell(index, y: Double(index) * 52))\n" }
        XCTAssertNil(ListClusterDetector.viewport(in: parsed(text)))
        XCTAssertEqual(ListClusterDetector.detect(in: parsed(text)).count, 0)
    }

    // MARK: - Resolution

    private func settingsLists() throws -> [ListCluster] {
        try lists(inFixture: "settings_root.txt")
    }

    func testBareSelectorResolvesAgainstTheOnlyList() throws {
        let lists = try settingsLists()
        let row = try XCTUnwrap(try? ListClusterDetector.row(
            for: XCTUnwrap(RowSelector.parse("@r3")), in: lists
        ).get())
        XCTAssertEqual(row.element.frame.y, lists[0].rows[2].element.frame.y)
    }

    func testNumberedSelectorPicksTheList() throws {
        let lists = try lists(inFixture: "language_sheet_modal.txt")
        let row = try XCTUnwrap(try? ListClusterDetector.row(
            for: XCTUnwrap(RowSelector.parse("@l1r2")), in: lists
        ).get())
        XCTAssertEqual(row.element.label, "Calendar, Gregorian")
    }

    /// A bare `@rN` on a screen with two lists is refused, not guessed. "The
    /// largest list" would read as working right up to the screen where the largest
    /// list is not the one the caller meant.
    func testBareSelectorIsAmbiguousWithTwoLists() throws {
        let lists = try lists(inFixture: "language_sheet_modal.txt")
        let result = ListClusterDetector.row(
            for: try XCTUnwrap(RowSelector.parse("@r2")), in: lists
        )
        guard case .failure(.ambiguous(_, let rowsPerList)) = result else {
            return XCTFail("expected .ambiguous, got \(result)")
        }
        XCTAssertEqual(rowsPerList, [7, 11])
    }

    func testFailureMatrix() throws {
        let selector = try XCTUnwrap(RowSelector.parse("@r2"))
        guard case .failure(.noLists) = ListClusterDetector.row(for: selector, in: []) else {
            return XCTFail("no lists must fail as .noLists")
        }

        let lists = try settingsLists()
        let beyond = ListClusterDetector.row(
            for: try XCTUnwrap(RowSelector.parse("@l4r1")), in: lists
        )
        guard case .failure(.listNotFound(_, let list, let count)) = beyond else {
            return XCTFail("expected .listNotFound, got \(beyond)")
        }
        XCTAssertEqual(list, 4)
        XCTAssertEqual(count, 1)

        let tooFar = ListClusterDetector.row(
            for: try XCTUnwrap(RowSelector.parse("@r9")), in: lists
        )
        guard case .failure(.rowNotFound(_, let rows)) = tooFar else {
            return XCTFail("expected .rowNotFound, got \(tooFar)")
        }
        XCTAssertEqual(rows, 8)
    }

    /// `locate` is the layer the poller and `resolve` share, so a row selector
    /// resolves identically for `tap`, `assert` and `wait`.
    func testLocateResolvesARowToItsCentre() throws {
        let elements = parsed(try fixture("settings_root.txt"))
        guard case .found(let found) = DebugDescriptionParser.locate(query: "@r2", in: elements) else {
            return XCTFail("@r2 must resolve on the Settings root")
        }
        let row = try XCTUnwrap(ListClusterDetector.detect(in: elements).first?.rows[1].element)
        XCTAssertEqual(found.centerX, row.frame.x + row.frame.w / 2)
        XCTAssertEqual(found.centerY, row.frame.y + row.frame.h / 2)
        XCTAssertEqual(found.matchCount, 1)

        guard case .rowFailed = DebugDescriptionParser.locate(query: "@r99", in: elements) else {
            return XCTFail("a row beyond the list must fail as .rowFailed, not .notFound")
        }
        // An ordinary query is untouched by the row branch.
        guard case .found(let general) = DebugDescriptionParser.locate(query: "General", in: elements) else {
            return XCTFail("an ordinary query must still resolve")
        }
        XCTAssertEqual(general.label, "General")
    }

    // MARK: - Envelopes

    private func errorObject(_ data: Data) throws -> [String: Any] {
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let separator = try XCTUnwrap(text.range(of: "\r\n\r\n"))
        let body = Data(String(text[separator.upperBound...]).utf8)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["success"] as? Bool, false)
        return try XCTUnwrap(json["error"] as? [String: Any])
    }

    /// Each failure gets the code whose repair matches it, and each carries its
    /// hint (SU2). `element_not_found` is deliberately not among them: none of these
    /// is repaired by hunting for a label.
    func testEachFailureCarriesItsOwnCodeAndHint() throws {
        let selector = try XCTUnwrap(RowSelector.parse("@r2"))
        let cases: [(RowResolutionError, String)] = [
            (.noLists(selector), "list_not_found"),
            (.listNotFound(selector, list: 4, count: 1), "list_not_found"),
            (.ambiguous(selector, rowsPerList: [6, 11]), "ambiguous_list"),
            (.rowNotFound(selector, rows: 8), "row_not_found"),
            (.gestureFailed("@r2 resolved, but the gesture failed"), "tap_failed"),
            (.notCheckable(selector, predicate: "hittable"), "row_unsupported"),
        ]
        for (error, code) in cases {
            let object = try errorObject(RowResponse.error(error))
            XCTAssertEqual(object["code"] as? String, code)
            XCTAssertEqual(object["message"] as? String, RowResponse.message(error))
            XCTAssertEqual(object["hint"] as? String, ErrorHint.standard(for: code), code)
        }
    }

    /// The messages name the selector and the numbers a caller needs to repair
    /// without another round trip.
    func testMessagesQuoteTheSelectorAndTheCounts() throws {
        let selector = try XCTUnwrap(RowSelector.parse("@r2"))
        XCTAssertTrue(RowResponse.message(.noLists(selector)).contains("@r2"))
        let ambiguous = RowResponse.message(.ambiguous(selector, rowsPerList: [6, 11]))
        XCTAssertTrue(ambiguous.contains("@l1 with 6 rows"), ambiguous)
        XCTAssertTrue(ambiguous.contains("@l2 with 11 rows"), ambiguous)
        XCTAssertTrue(RowResponse.message(.rowNotFound(selector, rows: 8)).contains("8 rows"))
    }

    /// A row selector is refused with its own code, not the alias one: a caller who
    /// wrote `@r3` and is told "does not take an @eN alias" goes looking for an
    /// alias they never used.
    func testRefusalNamesTheFormTheCallerWrote() throws {
        let row = try errorObject(XCTUnwrap(PositionalQuery.refusal(for: "@r3", command: "pinch")))
        XCTAssertEqual(row["code"] as? String, "row_unsupported")
        XCTAssertEqual(
            row["message"] as? String,
            AliasResponse.unsupportedMessage("pinch", kind: .row)
        )
        XCTAssertEqual(row["hint"] as? String, ErrorHint.standard(for: "row_unsupported"))

        let alias = try errorObject(XCTUnwrap(PositionalQuery.refusal(for: "@e3", command: "pinch")))
        XCTAssertEqual(alias["code"] as? String, "alias_unsupported")
        XCTAssertNil(PositionalQuery.refusal(for: "General", command: "pinch"))
    }

    /// tap and type must refuse identically on a focus-driven platform — they are
    /// the only two paths that carry a positional query to a coordinate.
    func testPlatformRefusalCoversBothForms() throws {
        for kind in [PositionalQuery.alias, .row] {
            let tap = try errorObject(TapHandler.responseData(from: .notSupportedOnPlatform(kind)))
            let type = try errorObject(
                TypeHandler.failureResponse(for: .notSupportedOnPlatform(kind))
            )
            XCTAssertEqual(
                tap["message"] as? String,
                AliasResponse.unsupportedMessage("tap on this platform", kind: kind, reason: .notCoordinateDriven)
            )
            XCTAssertEqual(
                type["message"] as? String,
                AliasResponse.unsupportedMessage("type on this platform", kind: kind, reason: .notCoordinateDriven)
            )
            XCTAssertEqual(tap["code"] as? String, type["code"] as? String)
        }
    }

    /// A row failure reaching `tap` or `type` keeps its own envelope rather than
    /// being flattened into `element_not_found`.
    func testHandlersForwardRowFailures() throws {
        let selector = try XCTUnwrap(RowSelector.parse("@r3"))
        let tap = try errorObject(TapHandler.responseData(from: .rowFailed(.noLists(selector))))
        XCTAssertEqual(tap["code"] as? String, "list_not_found")
        let type = try errorObject(
            TypeHandler.failureResponse(for: .rowFailed(.rowNotFound(selector, rows: 2)))
        )
        XCTAssertEqual(type["code"] as? String, "row_not_found")
    }

    // MARK: - Outline

    func testOutlineHeaderNamesEachListAndItsFirstRow() throws {
        let lists = try settingsLists()
        XCTAssertEqual(
            ListClusterDetector.outlineHeader(for: lists),
            ["# list @l1: 8 cell rows, first row @e\(lists[0].rows[0].actionableIndex + 1)"]
        )
    }

    /// Lists are detected at the depth `@rN` resolves at, never at the caller's
    /// `--depth`: a narrowed request would otherwise print a header naming lists that
    /// a later `tap '@l2r1'` never sees, and the numbering would shift silently.
    /// The `@eN` cross-reference is what gets dropped instead, because *that* is the
    /// part a narrowed listing renumbers.
    func testListsAreDetectedAtTheDepthRowsResolveAt() throws {
        let text = try fixture("settings_root.txt")
        let full = DebugDescriptionParser.parseActionable(fromRawDescription: text)
        let narrowed = DebugDescriptionParser.parseActionable(fromRawDescription: text, maxDepth: 6)

        XCTAssertEqual(narrowed.lists.map { $0.rows.count }, full.lists.map { $0.rows.count })
        XCTAssertLessThan(narrowed.elements.count, full.elements.count, "--depth must still narrow the listing")
        XCTAssertTrue(full.listsAreComparableToAliases)
        XCTAssertFalse(narrowed.listsAreComparableToAliases)

        let header = try XCTUnwrap(
            ListClusterDetector.outlineHeader(for: narrowed.lists, withAliasReference: false).first
        )
        XCTAssertEqual(header, "# list @l1: 8 cell rows")
        XCTAssertFalse(header.contains("@e"), "a narrowed listing renumbers @eN, so it must not be referenced")
    }

    /// A screen with no list gets no header and no leading blank line — an empty
    /// section would read as a list that failed to render.
    func testOutlineTextOmitsAnEmptyHeader() throws {
        let elements = "- button \"General\" @e1"
        XCTAssertEqual(ElementsHandler.outlineText(elements, lists: []), elements)

        let lists = try settingsLists()
        let text = ElementsHandler.outlineText(elements, lists: lists)
        XCTAssertTrue(text.hasPrefix("# list @l1:"))
        XCTAssertTrue(text.hasSuffix("\n" + elements))
        XCTAssertFalse(text.contains("\n\n"))
    }

    /// The header rides on `data.outline`, so `count` still counts elements — a
    /// caller that reads it to size a list must not see the headers in the total.
    func testHeaderDoesNotAffectTheElementCount() throws {
        let listing = DebugDescriptionParser.parseActionable(
            fromRawDescription: try fixture("settings_root.txt")
        )
        let rendered = OutlineRenderer.render(listing.elements)
        XCTAssertEqual(rendered.entries.count, listing.elements.count)
        XCTAssertEqual(
            ElementsHandler.outlineText(rendered.text, lists: listing.lists)
                .components(separatedBy: "\n").count,
            listing.elements.count + listing.lists.count
        )
    }

    // MARK: - Wiring
    //
    // Which commands refuse a positional query cannot be observed without a live
    // XCUIApplication, so it is checked at the source level — the same last-resort
    // technique as `ActionHandlerTests`. SU3 shipped a hole of exactly this shape:
    // the tvOS guard was written per call site and one path was missed.

    private static let handlersDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Handlers")

    private func handlerSource(_ name: String) throws -> String {
        try String(contentsOf: Self.handlersDirectory.appendingPathComponent(name), encoding: .utf8)
    }

    /// Handlers that read an element query and are accounted for **without** naming
    /// `PositionalQuery`, each with the reason. Written out so the scan below fails
    /// on a *new* handler rather than passing it silently — the same shape as
    /// `ErrorHint.deliberatelyWithoutHint`, and for the same reason: a hand-written
    /// list of the files that *do* guard is memory, while a list of the exceptions
    /// is a decision.
    private static let accountedForWithoutTheGuard = [
        "AssertHandler.swift": "refuses aliases and reports row failures through ElementPoller.Result",
        "WaitHandler.swift": "same, via ElementPoller.Result",
        "DoubleTapHandler.swift": "delegates to TapHandler.resolveAndTap",
        "LongPressHandler.swift": "delegates to TapHandler.resolveAndTap",
        "ActionHandler.swift":
            "delegates to the shared resolvers; its screenshot leg branches on both forms inline "
            + "because ActionHandlerTests pins the code literals at that site",
    ]

    /// Every handler that reads an element query either routes the question through
    /// `PositionalQuery` or is named above. A handler added later — SU5's, or any
    /// gesture handler — fails here instead of quietly matching `@r3` as a label.
    func testEveryQueryTakingHandlerAccountsForPositionalQueries() throws {
        let files = try FileManager.default
            .contentsOfDirectory(atPath: Self.handlersDirectory.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        XCTAssertGreaterThan(files.count, 15, "the scan found almost nothing — it is probably broken")

        var scanned = 0
        for file in files {
            let source = try handlerSource(file)
            let readsAQuery = source.contains("json[\"query\"]")
                || source.contains("json[\"to_query\"]")
                || source.contains("queryParams[\"element\"]")
                || source.contains("json[\"screenshot_element\"]")
            guard readsAQuery else { continue }
            scanned += 1
            if Self.accountedForWithoutTheGuard[file] != nil { continue }
            XCTAssertTrue(
                source.contains("PositionalQuery."),
                "\(file) reads an element query but never asks whether it is positional — "
                    + "guard it with PositionalQuery, or add it to accountedForWithoutTheGuard with the reason"
            )
        }
        XCTAssertGreaterThan(scanned, 8, "no handler was found to read a query — the scan is broken")
        XCTAssertEqual(
            Set(Self.accountedForWithoutTheGuard.keys).subtracting(files).sorted(), [],
            "these exceptions name handlers that no longer exist"
        )
    }

    /// The commands whose gesture needs a real `XCUIElement` must refuse *both*
    /// forms, so none may be left with an alias-only guard.
    func testNeedsElementCommandsHaveNoAliasOnlyGuard() throws {
        for file in [
            "PinchHandler.swift", "SliderHandler.swift", "ScreenshotHandler.swift",
            "DragHandler.swift", "SwipeHandler.swift", "ScrollToHandler.swift",
        ] {
            let source = try handlerSource(file)
            XCTAssertTrue(
                source.contains("PositionalQuery."),
                "\(file) must refuse positional queries through PositionalQuery"
            )
            XCTAssertFalse(
                source.contains("AliasResolver.isAlias("),
                "\(file) still has an alias-only guard, which lets an @rN through"
            )
        }
    }

    /// The coordinate-driven commands refuse both forms *before* the wait gate on a
    /// platform that has no coordinate path, and neither falls through to
    /// `ElementResolver`, where a positional query becomes a literal label.
    func testCoordinateCommandsGuardTheirPlatformAndTheirFallback() throws {
        for file in ["TapHandler.swift", "TypeHandler.swift"] {
            let source = try handlerSource(file)
            XCTAssertTrue(
                source.contains("PositionalQuery.kind(of: query), !PositionalQuery.isSupportedOnThisPlatform"),
                "\(file) must refuse every positional form on a focus-driven platform"
            )
            XCTAssertTrue(
                source.contains("case .row:"),
                "\(file) must keep a row selector out of the ElementResolver fallback"
            )
        }
    }
}
