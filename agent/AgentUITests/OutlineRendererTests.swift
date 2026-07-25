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

    /// Aliases are 1-based over the list as given — which `ElementsHandler` keeps
    /// unfiltered, so an alias means the same element whatever `--type` was passed.
    func testAliasesAreOneBasedOverTheListAsGiven() {
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

/// Coverage for SU3's alias rules. `AliasResolver.resolve` is pure over
/// (snapshot, current app, freshly derived identities), so the whole staleness
/// matrix runs here without a simulator.
final class AliasResolverTests: XCTestCase {

    private func identity(_ type: String, _ label: String, _ id: String = "") -> ElementSnapshot.Identity {
        ElementSnapshot.Identity(type: type, label: label, identifier: id)
    }

    private func snapshot(_ bundleId: String?, _ identities: [ElementSnapshot.Identity]) -> ElementSnapshot {
        ElementSnapshot(
            bundleId: bundleId,
            depth: DebugDescriptionParser.defaultActionableDepth,
            elements: identities.map { ["type": $0.type, "label": $0.label, "identifier": $0.identifier] }
        )
    }

    private let settings = "com.apple.Preferences"

    // MARK: - Syntax

    func testAliasSyntaxIsExact() {
        XCTAssertTrue(AliasResolver.isAlias("@e1"))
        XCTAssertTrue(AliasResolver.isAlias("@e42"))
        XCTAssertEqual(AliasResolver.index(of: "@e42"), 42)
    }

    /// `@` starts plenty of real labels, so only the `@e<digits>` shape is an
    /// alias — everything else stays an ordinary query.
    func testNonAliasQueriesAreNotClaimed() {
        for query in ["@e", "@e0", "@9", "@yoshi", "@e1x", "e1", "General", "", "@e-1", "@e 1"] {
            XCTAssertFalse(AliasResolver.isAlias(query), "\(query) must not be treated as an alias")
        }
    }

    /// The documented escape hatch for an app that really labels something `@e9`.
    func testTypedPrefixIsNeverAnAlias() {
        XCTAssertFalse(AliasResolver.isAlias("button:@e9"))
    }

    // MARK: - Resolution

    func testResolvesWhenTheIdentityAtThatPositionIsUnchanged() {
        let ids = [identity("button", "General"), identity("switch", "Wi-Fi")]
        let result = AliasResolver.resolve(
            alias: "@e2", snapshot: snapshot(settings, ids), currentBundleId: settings, fresh: ids
        )
        XCTAssertEqual(try? result.get(), 1)
    }

    /// Scrolling moves every row without changing which row it is. Frames are
    /// deliberately not part of the identity for exactly this case.
    func testScrollingDoesNotInvalidateAnAlias() {
        let ids = [identity("button", "General"), identity("button", "Accessibility")]
        // Same identities, different frames — frames never enter the comparison.
        let result = AliasResolver.resolve(
            alias: "@e1", snapshot: snapshot(settings, ids), currentBundleId: settings, fresh: ids
        )
        XCTAssertEqual(try? result.get(), 0)
    }

    func testNoSnapshotIsItsOwnError() {
        let result = AliasResolver.resolve(
            alias: "@e1", snapshot: nil, currentBundleId: settings, fresh: [identity("button", "A")]
        )
        XCTAssertEqual(result, .failure(.noSnapshot))
    }

    /// An alias taken in another app is stale by construction, whatever the
    /// identities happen to say — two apps can easily share a "Done" button.
    func testAliasFromAnotherAppIsStale() {
        let ids = [identity("button", "Done")]
        let result = AliasResolver.resolve(
            alias: "@e1", snapshot: snapshot(settings, ids), currentBundleId: "com.apple.MobileSMS", fresh: ids
        )
        assertStale(result)
    }

    func testAliasBeyondTheRecordedListIsStale() {
        let ids = [identity("button", "General")]
        assertStale(AliasResolver.resolve(
            alias: "@e5", snapshot: snapshot(settings, ids), currentBundleId: settings, fresh: ids
        ))
    }

    func testShorterScreenIsStale() {
        let recorded = [identity("button", "A"), identity("button", "B")]
        assertStale(AliasResolver.resolve(
            alias: "@e2", snapshot: snapshot(settings, recorded), currentBundleId: settings,
            fresh: [identity("button", "A")]
        ))
    }

    func testNavigationChangesTheIdentityAndIsStale() {
        let recorded = [identity("button", "General")]
        assertStale(AliasResolver.resolve(
            alias: "@e1", snapshot: snapshot(settings, recorded), currentBundleId: settings,
            fresh: [identity("button", "About")]
        ))
    }

    /// Duplicate identities are ordinary, not exotic: Messages lists the same
    /// conversation label twice, Calendar the same date string twice. Position
    /// still distinguishes them, and swapping two identical rows is not a change
    /// a caller can observe.
    func testDuplicateIdentitiesStillResolveByPosition() {
        let ids = [identity("cell", "+1 (888) 555-1212"), identity("cell", "+1 (888) 555-1212")]
        XCTAssertEqual(
            try? AliasResolver.resolve(
                alias: "@e2", snapshot: snapshot(settings, ids), currentBundleId: settings, fresh: ids
            ).get(),
            1
        )
    }

    /// The case aliases exist for: the nameless rows a query cannot name at all
    /// still address distinctly by position.
    func testNamelessElementsAreAddressable() {
        let ids = [identity("cell", ""), identity("cell", ""), identity("cell", "")]
        XCTAssertEqual(
            try? AliasResolver.resolve(
                alias: "@e3", snapshot: snapshot(settings, ids), currentBundleId: settings, fresh: ids
            ).get(),
            2
        )
    }

    private func assertStale(
        _ result: Result<Int, AliasResolutionError>,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        switch result {
        case .failure(.stale): break
        default: XCTFail("expected .stale, got \(result)", file: file, line: line)
        }
    }
}
