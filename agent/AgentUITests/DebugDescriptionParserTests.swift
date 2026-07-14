import XCTest

final class DebugDescriptionParserTests: XCTestCase {

    // MARK: - Fixture loading
    //
    // Fixtures are raw debugDescription captures stored as .txt files under
    // AgentUITests/Fixtures. We resolve them via `#filePath` (absolute path to
    // this source file captured at compile time) instead of Bundle resources,
    // because the UI test target has no Resources build phase. Tests run from
    // the same machine that built them, so the captured path stays valid.
    //
    // If remote CI is added later (`build-for-testing` on host A, `test-without-
    // building` on host B), `#filePath` will point at the A-side source tree
    // and break — switch to a Resources build phase at that point.

    private static let fixturesDirectory: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }()

    private func loadFixture(_ name: String) throws -> String {
        let url = Self.fixturesDirectory.appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - parseLines basic coverage

    func test_parseLines_ignoresCommentAndHeaderLines() throws {
        let fixture = try loadFixture("settings_root.txt")
        // The fixture begins with two `#` comment lines plus "Attributes:" /
        // "Element subtree:" metadata. None start with a known type, so they
        // must be filtered out — the real root must be the Application node.
        let root = DebugDescriptionParser.parseTree(fromRawDescription: fixture)
        XCTAssertEqual(root["type"] as? String, "application")
        XCTAssertFalse((root["children"] as? [[String: Any]])?.isEmpty ?? true)
    }

    // MARK: - A11: apostrophe labels are not truncated

    func test_parseLines_apostropheLabel_notTruncated() {
        let line = "    StaticText, 0x1, {{0.0, 0.0}, {100.0, 20.0}}, label: 'User's Name'"
        let parsed = DebugDescriptionParser.parseLines(line)
        XCTAssertEqual(parsed.first?.label, "User's Name")
    }

    func test_parseLines_labelBeforeAnotherAttribute_stopsAtClosingQuote() {
        let line = "    Button, 0x1, {{0.0, 0.0}, {44.0, 44.0}}, label: 'It's Fine', value: on"
        let parsed = DebugDescriptionParser.parseLines(line)
        XCTAssertEqual(parsed.first?.label, "It's Fine")
        XCTAssertEqual(parsed.first?.value, "on")
    }

    // MARK: - A12: Disabled flag vs. "Disabled" inside a label

    func test_parseLines_disabledFlag_marksDisabled() {
        let line = "    Button, 0x1, {{0.0, 0.0}, {44.0, 44.0}}, label: 'Save', Disabled"
        XCTAssertEqual(DebugDescriptionParser.parseLines(line).first?.enabled, false)
    }

    func test_parseLines_labelContainingDisabledWord_staysEnabled() {
        let line = "    StaticText, 0x1, {{0.0, 0.0}, {100.0, 20.0}}, label: 'Wi-Fi Disabled'"
        let parsed = DebugDescriptionParser.parseLines(line)
        XCTAssertEqual(parsed.first?.enabled, true)
        XCTAssertEqual(parsed.first?.label, "Wi-Fi Disabled")
    }

    func test_hasDisabledFlag_respectsQuotedCommas() {
        XCTAssertTrue(DebugDescriptionParser.hasDisabledFlag("Button, label: 'Save', Disabled"))
        XCTAssertFalse(DebugDescriptionParser.hasDisabledFlag("Button, label: 'Wi-Fi Disabled'"))
        XCTAssertFalse(DebugDescriptionParser.hasDisabledFlag("Button, label: 'a, Disabled, b'"))
    }

    /// Regression (Copilot review): an apostrophe inside a label must not desync
    /// quote tracking. `'It's, fine'` has both an apostrophe and a comma, so a
    /// naive per-`'` toggle would miss a trailing flag / spuriously detect one.
    func test_hasDisabledFlag_apostropheAndCommaInLabel() {
        XCTAssertTrue(DebugDescriptionParser.hasDisabledFlag("Button, label: 'It's, fine', Disabled"))
        XCTAssertFalse(DebugDescriptionParser.hasDisabledFlag("Button, label: 'a's, Disabled, b'"))
    }

    func test_parseLines_apostropheCommaLabel_disabledFlagDetected() {
        let line = "    Button, 0x1, {{0.0, 0.0}, {44.0, 44.0}}, label: 'It's, fine', Disabled"
        let parsed = DebugDescriptionParser.parseLines(line)
        XCTAssertEqual(parsed.first?.enabled, false)
        XCTAssertEqual(parsed.first?.label, "It's, fine")
    }

    /// Adversarial cases (in lieu of a verify pass): trailing-apostrophe label,
    /// no quoted attributes, empty label, and an unquoted `value:` that is the
    /// word "Disabled" (which must NOT count as the flag).
    func test_hasDisabledFlag_adversarial() {
        XCTAssertTrue(DebugDescriptionParser.hasDisabledFlag("Button, label: 'Boys'', Disabled"))
        XCTAssertTrue(DebugDescriptionParser.hasDisabledFlag("Button, 0x1, {{0.0, 0.0}, {10.0, 10.0}}, Disabled"))
        XCTAssertTrue(DebugDescriptionParser.hasDisabledFlag("Button, label: '', Disabled"))
        XCTAssertFalse(DebugDescriptionParser.hasDisabledFlag("Button, value: Disabled, label: 'x'"))
        XCTAssertFalse(DebugDescriptionParser.hasDisabledFlag("Button, label: 'Disabled'"))
    }

    // MARK: - findElement

    func test_findElement_bareLabel_returnsGeneralButton() throws {
        let parsed = try parsedElements(from: "settings_root.txt")
        let found = DebugDescriptionParser.findElement(query: "General", in: parsed)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.label, "General")
        XCTAssertEqual(found?.type, "button")
        XCTAssertEqual(found?.identifier, "com.apple.settings.general")
        // Center coordinates must be inside the frame.
        if let f = found {
            XCTAssertGreaterThan(f.frame.w, 0)
            XCTAssertGreaterThan(f.frame.h, 0)
            XCTAssertEqual(f.centerX, f.frame.x + f.frame.w / 2, accuracy: 0.001)
            XCTAssertEqual(f.centerY, f.frame.y + f.frame.h / 2, accuracy: 0.001)
        }
    }

    func test_findElement_identifierQuery_prefixed() throws {
        let parsed = try parsedElements(from: "settings_root.txt")
        let found = DebugDescriptionParser.findElement(
            query: "#com.apple.settings.general",
            in: parsed
        )
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.identifier, "com.apple.settings.general")
    }

    func test_findElement_typedQuery() throws {
        let parsed = try parsedElements(from: "settings_root.txt")
        let found = DebugDescriptionParser.findElement(query: "button:General", in: parsed)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.type, "button")
    }

    func test_findElement_missingElement_returnsNil() throws {
        let parsed = try parsedElements(from: "settings_root.txt")
        XCTAssertNil(DebugDescriptionParser.findElement(query: "NoSuchLabel12345", in: parsed))
    }

    func test_findElement_skipsZeroFrameElements() throws {
        // Synthetic fixture: the matching element has a zero frame, so findElement
        // must skip it and return nil rather than a degenerate center.
        let raw = """
         →Application, 0x1, pid: 1, label: 'App'
            Window (Main), 0x2, {{0.0, 0.0}, {402.0, 874.0}}
              Button, 0x3, {{0.0, 0.0}, {0.0, 0.0}}, label: 'Zero'
        """
        let parsed = parsedElementsFromRaw(raw)
        XCTAssertNil(DebugDescriptionParser.findElement(query: "Zero", in: parsed))
    }

    // MARK: - A13: ambiguous matches are reported, not silently resolved

    /// A disabled control whose same-label sibling is enabled — the exact shape
    /// that makes "prefer the enabled match" unsafe. `ElementPoller` observes
    /// through `findElement`, so preferring the enabled sibling would make
    /// `assert enabled 'General'` pass against the disabled control.
    private static let ambiguousGeneralTree = """
     →Application, 0x1, pid: 1, label: 'App'
        Window (Main), 0x2, {{0.0, 0.0}, {402.0, 874.0}}
          Button, 0x3, {{0.0, 100.0}, {200.0, 44.0}}, label: 'General', Disabled
          StaticText, 0x4, {{8.0, 110.0}, {100.0, 20.0}}, label: 'General'
    """

    func test_findElement_ambiguousMatch_keepsParseOrderAndDoesNotPreferEnabled() {
        let parsed = parsedElementsFromRaw(Self.ambiguousGeneralTree)
        let found = DebugDescriptionParser.findElement(query: "General", in: parsed)
        XCTAssertEqual(found?.type, "button", "parse order wins: the row, not its inner label")
        XCTAssertEqual(
            found?.enabled, false,
            "the disabled row must be observed as disabled — an enabled sibling must not mask it"
        )
        XCTAssertEqual(found?.matchCount, 2)
    }

    func test_findElement_ambiguousMatch_asDictSurfacesMatchCount() {
        let parsed = parsedElementsFromRaw(Self.ambiguousGeneralTree)
        let found = DebugDescriptionParser.findElement(query: "General", in: parsed)
        XCTAssertEqual(found?.asDict["match_count"] as? Int, 2)
    }

    func test_findElement_ambiguousMatch_reportsFirstEvenWhenLaterOneIsActionable() {
        let raw = """
         →Application, 0x1, pid: 1, label: 'App'
            Window (Main), 0x2, {{0.0, 0.0}, {402.0, 874.0}}
              StaticText, 0x3, {{0.0, 0.0}, {100.0, 20.0}}, label: 'General'
              Button, 0x4, {{0.0, 100.0}, {200.0, 44.0}}, label: 'General'
        """
        let found = DebugDescriptionParser.findElement(query: "General", in: parsedElementsFromRaw(raw))
        XCTAssertEqual(found?.type, "staticText", "no re-ranking; the caller sees match_count and can narrow")
        XCTAssertEqual(found?.matchCount, 2)
    }

    func test_findElement_singleMatch_omitsMatchCountKey() throws {
        // `#identifier` is unique in the fixture; the bare label "General" is not
        // (see the test below) — which is precisely why match_count exists.
        let parsed = try parsedElements(from: "settings_root.txt")
        let found = DebugDescriptionParser.findElement(query: "#com.apple.settings.general", in: parsed)
        XCTAssertEqual(found?.matchCount, 1)
        XCTAssertNil(
            found?.asDict["match_count"],
            "match_count is the ambiguity signal — an unambiguous match must not carry it"
        )
    }

    /// Real production data, not a synthetic tree: in Settings the "General" row
    /// is a Button whose inner StaticText carries the same label, so `tap General`
    /// has always been a two-way ambiguity resolved silently by parse order.
    /// It still resolves to the Button (first, and enabled) — but now says so.
    func test_findElement_realFixture_bareLabelIsAmbiguous_reportsMatchCount() throws {
        let parsed = try parsedElements(from: "settings_root.txt")
        let found = DebugDescriptionParser.findElement(query: "General", in: parsed)
        XCTAssertEqual(found?.type, "button", "the tappable row, not its inner label")
        XCTAssertEqual(found?.matchCount, 2)
        XCTAssertEqual(found?.asDict["match_count"] as? Int, 2)
    }

    // Zero matches → nil is already pinned by
    // `test_findElement_missingElement_returnsNil` above.

    // MARK: - A14: one element schema for every response path

    /// The eight keys `/tap`, `/type`, `/assert`, and `/scroll-to` all promise.
    private static let elementSchemaKeys: Set<String> = [
        "type", "label", "identifier", "value", "frame", "enabled", "selected", "hittable"
    ]

    func test_elementDict_emitsEveryKey_withNSNullForUnknowns() {
        let dict = ElementResolver.elementDict(
            type: "button", label: "Save", identifier: "save", value: nil,
            frame: (x: 1, y: 2, w: 3, h: 4),
            enabled: true, selected: nil, hittable: nil
        )
        XCTAssertEqual(Set(dict.keys), Self.elementSchemaKeys)
        XCTAssertTrue(dict["value"] is NSNull, "unknown value must be NSNull, not an absent key")
        XCTAssertTrue(dict["selected"] is NSNull)
        XCTAssertTrue(dict["hittable"] is NSNull)
        XCTAssertEqual(dict["enabled"] as? Bool, true)
        XCTAssertEqual(dict["frame"] as? [String: Double], ["x": 1, "y": 2, "width": 3, "height": 4])
    }

    /// `nil` ("this element has no value") and `""` ("its value is empty") are
    /// different facts. Folding them together would make "the field I just
    /// cleared is now empty" inexpressible.
    func test_elementDict_nilValue_isNSNull_butEmptyStringSurvives() {
        func value(_ raw: String?) -> Any {
            ElementResolver.elementDict(
                type: "textField", label: "", identifier: "", value: raw,
                frame: (x: 0, y: 0, w: 10, h: 10),
                enabled: true, selected: false, hittable: true
            )["value"]!
        }
        XCTAssertTrue(value(nil) is NSNull, "no value concept at all")
        XCTAssertEqual(value("") as? String, "", "an empty value is still a value")
    }

    /// The parser only ever sees `""` when debugDescription printed no value
    /// attribute — that is "no value", so `asDict` must map it to null.
    func test_foundElementAsDict_missingValueAttribute_isNSNull() {
        let raw = """
         →Application, 0x1, pid: 1, label: 'App'
            Window (Main), 0x2, {{0.0, 0.0}, {402.0, 874.0}}
              Button, 0x3, {{0.0, 100.0}, {200.0, 44.0}}, label: 'Go'
        """
        let found = DebugDescriptionParser.findElement(query: "Go", in: parsedElementsFromRaw(raw))
        XCTAssertTrue(found?.asDict["value"] is NSNull)
    }

    func test_elementDict_unknownFieldsAreNSNull() {
        let dict = ElementResolver.elementDict(
            type: "textField", label: "", identifier: "", value: nil,
            frame: (x: 0, y: 0, w: 10, h: 10),
            enabled: true, selected: nil, hittable: nil
        )
        XCTAssertTrue(dict["selected"] is NSNull)
        XCTAssertTrue(dict["hittable"] is NSNull)
    }

    func test_elementDict_presentValue_roundTrips() {
        let dict = ElementResolver.elementDict(
            type: "textField", label: "Email", identifier: "email", value: "a@b.c",
            frame: (x: 0, y: 0, w: 10, h: 10),
            enabled: false, selected: true, hittable: false
        )
        XCTAssertEqual(dict["value"] as? String, "a@b.c")
        XCTAssertEqual(dict["enabled"] as? Bool, false)
    }

    /// The A14 bug: `/tap` returned `FoundElement.asDict` on the fast path and
    /// `ElementResolver.describe` on the fallback path, and the two disagreed on
    /// which keys existed. `describe` cannot be called without a live
    /// XCUIApplication, so pin its shape through the builder it now delegates to.
    func test_foundElementAsDict_andDescribeShape_haveIdenticalKeySets() {
        let found = DebugDescriptionParser.FoundElement(
            type: "button", label: "Save", identifier: "save", value: "",
            centerX: 50, centerY: 50,
            frame: (x: 0, y: 0, w: 100, h: 100),
            enabled: true, matchCount: 1, hittable: nil
        )
        // What ElementResolver.describe(_:) produces: knows `selected`, not `hittable`.
        let describeShaped = ElementResolver.elementDict(
            type: "button", label: "Save", identifier: "save", value: nil,
            frame: (x: 0, y: 0, w: 100, h: 100),
            enabled: true, selected: false, hittable: nil
        )
        XCTAssertEqual(Set(found.asDict.keys), Set(describeShaped.keys))
        XCTAssertEqual(Set(found.asDict.keys), Self.elementSchemaKeys)
    }

    /// `match_count` is the single conditional key, and only on the parser path.
    func test_foundElementAsDict_ambiguous_addsOnlyMatchCount() {
        let found = DebugDescriptionParser.FoundElement(
            type: "button", label: "Save", identifier: "save", value: "on",
            centerX: 50, centerY: 50,
            frame: (x: 0, y: 0, w: 100, h: 100),
            enabled: true, matchCount: 3, hittable: true
        )
        XCTAssertEqual(Set(found.asDict.keys), Self.elementSchemaKeys.union(["match_count"]))
        XCTAssertEqual(found.asDict["match_count"] as? Int, 3)
        XCTAssertEqual(found.asDict["hittable"] as? Bool, true)
        XCTAssertEqual(found.asDict["value"] as? String, "on")
        XCTAssertTrue(found.asDict["selected"] is NSNull, "a text-tree parse cannot know `selected`")
    }

    /// Every response element dict must survive JSONSerialization — NSNull is
    /// legal JSON null, a raw Swift `nil` or tuple would not be.
    func test_elementDict_isJSONSerializable() throws {
        let dict = ElementResolver.elementDict(
            type: "button", label: "Save", identifier: "save", value: nil,
            frame: (x: 1, y: 2, w: 3, h: 4),
            enabled: true, selected: nil, hittable: nil
        )
        XCTAssertTrue(JSONSerialization.isValidJSONObject(dict))
        let data = try JSONSerialization.data(withJSONObject: dict)
        let round = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertTrue(round?["value"] is NSNull)
    }

    // MARK: - parseActionableList

    func test_parseActionableList_includesGeneralButton() throws {
        // Pin the production contract, not a surface string: the Settings
        // General entry must appear as a button with Apple's stable
        // `com.apple.settings.general` identifier. A label-only check would
        // still pass if parseActionableList dropped the parent entry but kept
        // some inner StaticText that happens to read "General".
        let fixture = try loadFixture("settings_root.txt")
        let actionable = DebugDescriptionParser.parseActionableList(fromRawDescription: fixture)
        let match = actionable.first { entry in
            (entry["type"] as? String) == "button"
                && (entry["identifier"] as? String) == "com.apple.settings.general"
                && (entry["label"] as? String) == "General"
        }
        XCTAssertNotNil(match, "General button must be in the actionable list with its production identifier")
    }

    func test_parseActionableList_returnsFramedEntries() throws {
        let fixture = try loadFixture("settings_root.txt")
        let actionable = DebugDescriptionParser.parseActionableList(fromRawDescription: fixture)
        XCTAssertFalse(actionable.isEmpty)
        for entry in actionable {
            let frame = entry["frame"] as? [String: Any]
            XCTAssertNotNil(frame, "actionable entries must carry a frame")
        }
    }

    // MARK: - Modal sheet fixture

    func test_findElement_englishCellBehindLanguageSheet() throws {
        // The "English" cell still exists in the underlying Language & Region
        // screen while the Add Language sheet is presented on top. findElement
        // must return the underlying cell so the poller can hand it to
        // isHittable for the authoritative visibility check.
        let parsed = try parsedElements(from: "language_sheet_modal.txt")
        let found = DebugDescriptionParser.findElement(query: "English", in: parsed)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.identifier, "en-US")
        XCTAssertEqual(found?.type, "cell")
    }

    func test_parseLines_retainsSelectLanguageNavigationBar() throws {
        // Anchor test for the parser's sheet-root retention. The previous
        // version of this test grepped the raw fixture for "Select Language",
        // which would stay green even if parseLines started dropping the
        // NavigationBar node. Walking the parsed element list instead means a
        // parser regression — the kind that would hide a modal from
        // hittable/poller logic — fails loudly.
        let parsed = try parsedElements(from: "language_sheet_modal.txt")
        let navBar = parsed.first { element in
            element.type == "navigationBar" && element.identifier == "Select Language"
        }
        XCTAssertNotNil(navBar, "Sheet's Select Language NavigationBar must survive parseLines")
    }

    // MARK: - Helpers

    private func parsedElements(from fixtureName: String) throws -> [DebugDescriptionParser.ParsedElement] {
        let raw = try loadFixture(fixtureName)
        return parsedElementsFromRaw(raw)
    }

    private func parsedElementsFromRaw(_ raw: String) -> [DebugDescriptionParser.ParsedElement] {
        DebugDescriptionParser.parseLines(raw)
    }
}
