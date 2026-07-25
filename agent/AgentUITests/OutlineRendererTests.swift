import XCTest

/// Coverage for `OutlineRenderer` (SU1) — the pure element-list → text renderer.
/// It consumes the dictionaries `parseActionableList` produces, so every case
/// here runs without a live `XCUIApplication`.
final class OutlineRendererTests: XCTestCase {

    private func element(
        type: String = "button",
        label: String = "",
        identifier: String = "",
        value: String? = nil,
        enabled: Bool = true
    ) -> [String: Any] {
        var dict: [String: Any] = [
            "type": type,
            "label": label,
            "identifier": identifier,
            "enabled": enabled
        ]
        if let value { dict["value"] = value }
        return dict
    }

    // MARK: - Line shape

    func testRendersAgentBrowserSkeletonWithCheapRef() {
        let rendered = OutlineRenderer.render([
            element(type: "searchField", label: "Search"),
            element(label: "General"),
            element(type: "switch", label: "Wi-Fi", value: "1")
        ])

        XCTAssertEqual(rendered.text, """
        - searchField "Search" @e1
        - button "General" @e2
        - switch "Wi-Fi" @e3 [value=1]
        """)
    }

    func testDisabledAttributePrecedesValue() {
        let line = OutlineRenderer.line(
            for: element(type: "slider", label: "Volume", value: "0.5", enabled: false),
            alias: "@e7"
        )
        XCTAssertEqual(line, "- slider \"Volume\" @e7 [disabled] [value=0.5]")
    }

    /// The type is `normalizeTypeName`'s camelCase verbatim. Translating to ARIA
    /// would need an invented name for types ARIA has no word for, and
    /// lowercasing yields `searchfield` — neither vocabulary, and not what the
    /// caller would then pass to `--type`.
    func testRoleIsTheXCUITestTypeVerbatim() {
        let line = OutlineRenderer.line(for: element(type: "segmentedControl", label: "Mode"), alias: "@e1")
        XCTAssertEqual(line, "- segmentedControl \"Mode\" @e1")
    }

    // MARK: - Name fallback

    func testFallsBackToIdentifierWhenLabelIsEmpty() {
        let line = OutlineRenderer.line(for: element(type: "cell", identifier: "row-3"), alias: "@e2")
        XCTAssertEqual(line, "- cell \"row-3\" @e2")
    }

    /// An element whose name simpilot cannot know drops the name slot rather than
    /// rendering `""`, which would read as "this element has an empty label".
    func testOmitsNameSlotWhenLabelAndIdentifierAreBothEmpty() {
        let line = OutlineRenderer.line(for: element(type: "cell"), alias: "@e2")
        XCTAssertEqual(line, "- cell @e2")
    }

    func testValueIsOmittedWhenEmpty() {
        let line = OutlineRenderer.line(for: element(label: "OK", value: ""), alias: "@e1")
        XCTAssertEqual(line, "- button \"OK\" @e1")
    }

    // MARK: - Escaping

    func testEscapesQuotesAndBackslashesInTheName() {
        let line = OutlineRenderer.line(for: element(label: #"Say "hi" \ bye"#), alias: "@e1")
        XCTAssertEqual(line, #"- button "Say \"hi\" \\ bye" @e1"#)
    }

    /// A literal newline inside a name would forge an extra element line, so the
    /// line-based format wins over round-tripping the exact label.
    func testCollapsesNewlinesAndTabsToSpaces() {
        let line = OutlineRenderer.line(for: element(label: "Line1\nLine2\tTabbed"), alias: "@e1")
        XCTAssertEqual(line, "- button \"Line1 Line2 Tabbed\" @e1")
        XCTAssertEqual(line.components(separatedBy: "\n").count, 1)
    }

    /// The attribute slot closes on `]`, not on a quote, so a quote inside it is
    /// escaped nowhere and a `]` is escaped instead — each slot escapes only what
    /// would end it early.
    func testValueEscapesItsOwnDelimiterNotTheNameDelimiter() {
        let quoted = OutlineRenderer.line(for: element(type: "textField", label: "Note", value: "a\"b"), alias: "@e1")
        XCTAssertEqual(quoted, "- textField \"Note\" @e1 [value=a\"b]")

        let bracketed = OutlineRenderer.line(for: element(type: "textField", label: "Note", value: "a]b"), alias: "@e1")
        XCTAssertEqual(bracketed, #"- textField "Note" @e1 [value=a\]b]"#)
    }

    /// Conversely a `]` in the name is left alone — the name is closed by its
    /// quote, and escaping it would spend bytes on a character that ends nothing.
    func testNameDoesNotEscapeTheAttributeDelimiter() {
        let line = OutlineRenderer.line(for: element(label: "Item [1]"), alias: "@e1")
        XCTAssertEqual(line, "- button \"Item [1]\" @e1")
    }

    /// A label that itself contains `@e2` must not be mistaken for the alias: the
    /// ref is the token after the closing quote, and the label stays quoted.
    func testLabelContainingAnAliasLikeTokenStaysInsideQuotes() {
        let line = OutlineRenderer.line(for: element(label: "Reply to @e2 people"), alias: "@e9")
        XCTAssertEqual(line, "- button \"Reply to @e2 people\" @e9")
    }

    // MARK: - Aliases

    /// Aliases number the *rendered* lines. `ElementsHandler` filters before
    /// rendering, so numbering the pre-filter list would hand SU3's cache aliases
    /// that point at elements the caller never saw.
    func testAliasesAreOneBasedOverRenderedLines() {
        let rendered = OutlineRenderer.render([
            element(label: "A"), element(label: "B"), element(label: "C")
        ])
        XCTAssertEqual(rendered.entries.map(\.alias), ["@e1", "@e2", "@e3"])
        XCTAssertEqual(rendered.entries.map { $0.element["label"] as? String }, ["A", "B", "C"])
    }

    func testEntriesPairWithTheLinesInOrder() {
        let rendered = OutlineRenderer.render([element(label: "A"), element(label: "B")])
        let lines = rendered.text.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, rendered.entries.count)
        for (line, entry) in zip(lines, rendered.entries) {
            XCTAssertTrue(line.hasSuffix(entry.alias), "\(line) should end with \(entry.alias)")
        }
    }

    func testEmptyListRendersEmptyText() {
        let rendered = OutlineRenderer.render([])
        XCTAssertEqual(rendered.text, "")
        XCTAssertTrue(rendered.entries.isEmpty)
    }

    // MARK: - Stability

    /// Byte-identical output for identical input is what makes two snapshots
    /// diffable — the reason the format has no column alignment, whose widths
    /// would shift for every line as soon as one long label appeared.
    func testSameInputRendersByteIdenticalOutput() {
        let input = [element(label: "General"), element(type: "switch", label: "Wi-Fi", value: "1")]
        XCTAssertEqual(OutlineRenderer.render(input).text, OutlineRenderer.render(input).text)
    }

    func testNoLineContainsRunsOfSpaces() {
        let rendered = OutlineRenderer.render([
            element(label: "A"),
            element(label: "A much longer label than the others")
        ])
        XCTAssertFalse(rendered.text.contains("  "), "outline must not align columns")
    }

    // MARK: - Size

    /// The point of the format. Not a precise budget — just a guard that a change
    /// reintroducing frames or key names would trip.
    func testOutlineIsFarSmallerThanTheJSONItReplaces() throws {
        let elements = (1...30).map { index in
            var dict = element(label: "Item \(index)")
            dict["frame"] = ["x": 20.0, "y": Double(100 + index * 44), "width": 353.0, "height": 44.0]
            return dict
        }
        let outline = OutlineRenderer.render(elements).text
        let json = try JSONSerialization.data(withJSONObject: elements)
        XCTAssertLessThan(outline.utf8.count * 4, json.count, "outline should be well under a quarter of the JSON")
    }
}

/// Coverage for `ElementsHandler`'s pure request rules. They live as static
/// functions precisely so they can be exercised here, without a live app.
final class ElementsHandlerFormatTests: XCTestCase {

    // MARK: - Format

    func testFormatAcceptsBothSupportedValues() {
        XCTAssertTrue(ElementsHandler.isSupportedFormat("json"))
        XCTAssertTrue(ElementsHandler.isSupportedFormat("outline"))
        XCTAssertFalse(ElementsHandler.isSupportedFormat("yaml"))
        XCTAssertFalse(ElementsHandler.isSupportedFormat(""))
    }

    /// The handler lowercases before this check, so `?format=OUTLINE` over raw
    /// HTTP behaves like the CLI, which lowercases in `ElementsFormatArg`.
    func testFormatComparisonIsAgainstTheLowercasedValue() {
        XCTAssertFalse(ElementsHandler.isSupportedFormat("OUTLINE"))
        XCTAssertTrue(ElementsHandler.isSupportedFormat("OUTLINE".lowercased()))
    }

    // MARK: - Mode resolution

    func testLevelMapsToMode() {
        XCTAssertEqual(ElementsHandler.resolveMode(level: "0", mode: nil), "summary")
        XCTAssertEqual(ElementsHandler.resolveMode(level: "1", mode: nil), "actionable")
        XCTAssertEqual(ElementsHandler.resolveMode(level: "2", mode: nil), "compact")
        XCTAssertEqual(ElementsHandler.resolveMode(level: "3", mode: nil), "tree")
        XCTAssertEqual(ElementsHandler.resolveMode(level: "9", mode: nil), "tree")
    }

    func testLevelWinsOverModeAndNonNumericLevelFallsBack() {
        XCTAssertEqual(ElementsHandler.resolveMode(level: "1", mode: "compact"), "actionable")
        XCTAssertEqual(ElementsHandler.resolveMode(level: "abc", mode: "compact"), "compact")
        XCTAssertEqual(ElementsHandler.resolveMode(level: nil, mode: nil), "tree")
    }

    // MARK: - Outline / level conflict

    /// Neither parameter present is an absence, not a request for the tree — the
    /// common `elements --format outline` must not reject itself.
    func testOutlineWithNoLevelOrModeIsNotAConflict() {
        XCTAssertFalse(ElementsHandler.outlineConflictsWithRequestedMode(format: "outline", level: nil, mode: nil))
    }

    func testOutlineWithAnAgreeingLevelIsNotAConflict() {
        XCTAssertFalse(ElementsHandler.outlineConflictsWithRequestedMode(format: "outline", level: "1", mode: nil))
        XCTAssertFalse(
            ElementsHandler.outlineConflictsWithRequestedMode(format: "outline", level: nil, mode: "actionable")
        )
    }

    func testOutlineWithADisagreeingLevelIsAConflict() {
        for level in ["0", "2", "3"] {
            XCTAssertTrue(
                ElementsHandler.outlineConflictsWithRequestedMode(format: "outline", level: level, mode: nil),
                "level=\(level) should conflict with format=outline"
            )
        }
        XCTAssertTrue(
            ElementsHandler.outlineConflictsWithRequestedMode(format: "outline", level: nil, mode: "compact")
        )
    }

    /// The rule is outline-specific: JSON keeps every level it always had.
    func testJSONFormatNeverConflicts() {
        for level in ["0", "1", "2", "3"] {
            XCTAssertFalse(
                ElementsHandler.outlineConflictsWithRequestedMode(format: "json", level: level, mode: nil)
            )
        }
    }
}
