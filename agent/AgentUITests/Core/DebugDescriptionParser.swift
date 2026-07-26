import Foundation
import XCTest

/// Parses XCUIElement.debugDescription into structured element data.
/// This is ~50-80x faster than walking the element tree via XCUITest APIs
/// because debugDescription fetches the entire tree in a single IPC call,
/// while children(matching:) triggers a separate IPC call per node.
enum DebugDescriptionParser {

    struct ParsedElement {
        let type: String
        let label: String
        let identifier: String
        let value: String
        let frame: (x: Double, y: Double, w: Double, h: Double)
        let enabled: Bool
        let depth: Int
        var children: [ParsedElement]
    }

    // MARK: - Public API

    /// Parse debugDescription into a full tree (Full element tree as nested dictionaries).
    static func parseTree(from app: XCUIApplication, maxDepth: Int = 10) -> [String: Any] {
        parseTree(fromRawDescription: AXTree.description(of: app), maxDepth: maxDepth)
    }

    /// Parse debugDescription into an actionable flat list (Flat list of interactive elements).
    static func parseActionableList(from app: XCUIApplication, maxDepth: Int = 20) -> [[String: Any]] {
        parseActionableList(fromRawDescription: AXTree.description(of: app), maxDepth: maxDepth)
    }

    /// Parse debugDescription into a summary of element counts (Element type counts).
    static func parseSummary(from app: XCUIApplication) -> [String: Any] {
        let elements = parseLines(AXTree.description(of: app))
        return buildSummary(from: elements)
    }

    /// Parse debugDescription into a compact tree (Tree with single-child passthrough nodes collapsed).
    static func parseCompactTree(from app: XCUIApplication, maxDepth: Int = 10) -> [String: Any] {
        let elements = parseLines(AXTree.description(of: app))
        guard let root = buildCompactTree(from: elements, maxDepth: maxDepth) else {
            return [:]
        }
        return root
    }

    // MARK: - Raw-string overloads (testable without a live XCUIApplication)

    /// Same as `parseTree(from:maxDepth:)` but consumes a raw debugDescription
    /// string. Kept for unit tests; production callers should use the XCUIApplication
    /// overload above.
    static func parseTree(fromRawDescription desc: String, maxDepth: Int = 10) -> [String: Any] {
        let elements = parseLines(desc)
        guard let root = buildTree(from: elements, maxDepth: maxDepth) else {
            return [:]
        }
        return root
    }

    /// Raw-string counterpart of `parseActionableList(from:maxDepth:)`.
    static func parseActionableList(fromRawDescription desc: String, maxDepth: Int = 20) -> [[String: Any]] {
        let elements = parseLines(desc)
        return collectActionable(from: elements, maxDepth: maxDepth)
    }

    /// The actionable list and the repeating lists inside it, from **one** parse.
    ///
    /// `elements --format outline` needs both, and the row numbering only lines up
    /// with the `@eN` numbering if they come from the same tree: two calls would pay
    /// a second ~0.2s `debugDescription` IPC *and* let a screen change between them,
    /// so a header could name a list the element lines below no longer describe.
    struct ActionableListing {
        /// At the caller's depth — `--depth` narrows what is listed and numbered.
        let elements: [[String: Any]]
        /// At `defaultActionableDepth`, always: see `listsAreComparableToAliases`.
        let lists: [ListCluster]
        /// Whether a row's `actionableIndex` names the same line as this listing's
        /// `@eN`. False when the caller narrowed `--depth`, because the lists are
        /// deliberately detected at the depth a *later command* resolves `@rN` at
        /// (a `tap` carries no depth), while the elements honor the request. SU3
        /// carried the depth in `ElementSnapshot` for exactly this reason; a row
        /// selector has no snapshot to carry it in, so the two are reconciled by
        /// pinning detection and dropping the cross-reference instead of letting a
        /// header number a list that `@lM` will not resolve to.
        let listsAreComparableToAliases: Bool
    }

    static func parseActionable(
        from app: XCUIApplication, maxDepth: Int = defaultActionableDepth
    ) -> ActionableListing {
        parseActionable(fromRawDescription: AXTree.description(of: app), maxDepth: maxDepth)
    }

    static func parseActionable(
        fromRawDescription desc: String, maxDepth: Int = defaultActionableDepth
    ) -> ActionableListing {
        let parsed = parseLines(desc)
        return ActionableListing(
            elements: collectActionable(from: parsed, maxDepth: maxDepth),
            lists: ListClusterDetector.detect(in: parsed, maxDepth: defaultActionableDepth),
            listsAreComparableToAliases: maxDepth == defaultActionableDepth
        )
    }

    // MARK: - Fast Element Resolution

    struct FoundElement {
        let type: String
        let label: String
        let identifier: String
        let value: String
        let centerX: Double
        let centerY: Double
        let frame: (x: Double, y: Double, w: Double, h: Double)
        let enabled: Bool
        /// How many elements in the tree matched the query. `> 1` means the
        /// query was ambiguous and `findElement` picked one of them.
        let matchCount: Int
        /// Set only after the poller requests an authoritative hittability check.
        /// Nil on the fast path (no XCUIElement.isHittable IPC performed).
        var hittable: Bool?

        /// JSON-ready dict for HTTP responses. Shared by TapHandler and AssertHandler.
        /// Delegates to the one shared builder so this path and
        /// `ElementResolver.describe` cannot disagree on the schema. `selected`
        /// is nil because a text-tree parse cannot know it.
        ///
        /// `value` is `""` here when debugDescription printed no value attribute
        /// at all, which is "no value", not "an empty value" — the distinction
        /// `elementDict` preserves for the resolver path.
        var asDict: [String: Any] {
            var dict = ElementResolver.elementDict(
                type: type, label: label, identifier: identifier,
                value: value.isEmpty ? nil : value, frame: frame,
                enabled: enabled, selected: nil, hittable: hittable
            )
            // Only surfaced when the query was ambiguous — its presence is the
            // signal, so an unambiguous match must not carry a `1`.
            if matchCount > 1 {
                dict["match_count"] = matchCount
            }
            return dict
        }
    }

    /// What a query resolved to, once `@eN` aliases are in play.
    ///
    /// A failed alias is its own case rather than `notFound`: "the screen changed
    /// since you listed it" is a different instruction to the caller than "no such
    /// element", and collapsing them would send an agent hunting for a label when
    /// what it needs is a fresh `elements --format outline`.
    enum QueryResolution {
        case found(FoundElement)
        case notFound
        case aliasFailed(AliasResolutionError)
        /// An `@rN` / `@lMrN` row selector that named no row on this screen.
        case rowFailed(RowResolutionError)
    }

    /// What a query resolved to against an already-parsed tree.
    ///
    /// Separate from `QueryResolution` because it needs no snapshot and no bundle
    /// ID: `locate` is the layer both the poller and `resolve` share, and aliases —
    /// which are the only form that needs those two — are handled above it.
    enum Located {
        case found(FoundElement)
        case notFound
        case rowFailed(RowResolutionError)

        /// The same outcome as `resolve` reports. The two enums are deliberately
        /// separate — `ElementPoller` would otherwise have to handle an
        /// `.aliasFailed` it can never see — so the widening lives here, once,
        /// rather than inline at the caller.
        var asQueryResolution: QueryResolution {
            switch self {
            case .found(let element): return .found(element)
            case .notFound: return .notFound
            case .rowFailed(let error): return .rowFailed(error)
            }
        }
    }

    /// The one place a query that is *not* an alias is turned into an element.
    ///
    /// Row selectors (SU4) resolve here rather than in `resolve` so the poller gets
    /// them too: unlike an alias, a row selector is re-derived from the live tree on
    /// every observation, so `assert enabled '@r3'` and `tap '@r3' --timeout 2000`
    /// are coherent and simply work. An ordinary query falls through to
    /// `findElement` with its behavior untouched.
    static func locate(
        query: String,
        in elements: [ParsedElement],
        maxDepth: Int = defaultActionableDepth
    ) -> Located {
        guard let selector = RowSelector.parse(query) else {
            return findElement(query: query, in: elements).map(Located.found) ?? .notFound
        }
        let lists = ListClusterDetector.detect(in: elements, maxDepth: maxDepth)
        switch ListClusterDetector.row(for: selector, in: lists) {
        case .failure(let error):
            return .rowFailed(error)
        case .success(let row):
            return .found(toFound(row.element, matchCount: 1))
        }
    }

    /// `locate` against the live tree. One `debugDescription` IPC, same as
    /// `findElement(query:in:)`, which it replaces on the polling path.
    static func locate(query: String, in app: XCUIApplication) -> Located {
        locate(query: query, in: parseLines(AXTree.description(of: app)))
    }

    /// The one entry point for a query that may be an `@eN` alias.
    ///
    /// A non-alias query falls straight through to `findElement` with its behavior
    /// untouched — `ElementPoller` observes through here, so anything else would
    /// change what `assert enabled 'X'` sees.
    ///
    /// The alias path re-derives the actionable list from the *live* tree and
    /// checks position N still holds the recorded identity, then reports that
    /// element's current geometry. The snapshot supplies identity only; trusting
    /// its coordinates would tap where the row used to be.
    static func resolve(
        query: String,
        in app: XCUIApplication,
        snapshot: ElementSnapshot?,
        currentBundleId: String?
    ) -> QueryResolution {
        guard AliasResolver.isAlias(query) else {
            return locate(query: query, in: app).asQueryResolution
        }

        // `debugDescription` is the expensive part (~0.2s of IPC). With no
        // snapshot the answer is known without looking at the screen at all.
        guard let snapshot else { return .aliasFailed(.noSnapshot) }

        // Re-derive at the *snapshot's* depth, not a constant: `--depth` changes
        // the list's length, and comparing position N across two depths would
        // shift every alias with nothing to report.
        let parsed = parseLines(AXTree.description(of: app))
        let depth = snapshot.depth
        let fresh = collectActionable(from: parsed, maxDepth: depth)
            .map(ElementSnapshot.Identity.init(element:))

        switch AliasResolver.resolve(
            alias: query, snapshot: snapshot, currentBundleId: currentBundleId, fresh: fresh
        ) {
        case .failure(let error):
            return .aliasFailed(error)
        case .success(let position):
            // Re-find the element in the parsed tree to recover its frame: the
            // actionable dicts carry one, but `toFound` is the single builder for
            // `FoundElement` and re-deriving centers here would duplicate it.
            guard let element = actionableElement(at: position, in: parsed, maxDepth: depth) else {
                return .aliasFailed(.stale("\(query) no longer resolves to an element"))
            }
            // `findElement` drops zero-size elements; the actionable list does not,
            // so an alias can name one. Its center is (0, 0), which would tap the
            // screen corner and report success — refuse instead.
            guard element.frame.w > 0, element.frame.h > 0 else {
                return .aliasFailed(.stale("\(query) names an element with no on-screen frame"))
            }
            return .found(toFound(element, matchCount: 1))
        }
    }

    /// The depth the actionable list is derived at when the caller names none.
    /// `ElementsHandler` uses the same default, so an outline taken without
    /// `--depth` and an alias resolved against it walk the same list.
    static let defaultActionableDepth = 20

    private static func actionableElement(
        at position: Int, in elements: [ParsedElement], maxDepth: Int
    ) -> ParsedElement? {
        var seen = 0
        for element in elements where isActionable(element, withinDepth: maxDepth) {
            if seen == position { return element }
            seen += 1
        }
        return nil
    }

    /// Find an element by query in the debugDescription and return its center coordinates.
    /// This bypasses XCUITest's slow element resolution (~24s) by parsing the text tree (~0.2s).
    static func findElement(query: String, in app: XCUIApplication) -> FoundElement? {
        let desc = AXTree.description(of: app)
        let elements = parseLines(desc)
        return findElement(query: query, in: elements)
    }

    /// Testable overload that operates on a pre-parsed element list.
    ///
    /// A query can match several elements — in Settings the "General" row is a
    /// Button whose inner StaticText carries the same label, so a bare label is
    /// routinely a two-way match. The winner stays the first in parse order
    /// (parent before child, i.e. the actionable row), but the count rides along
    /// in `matchCount` so callers can surface the ambiguity instead of hiding it.
    ///
    /// Deliberately *not* "prefer the enabled match": `ElementPoller` observes
    /// through this same function, so preferring an enabled sibling would let
    /// `assert enabled 'X'` pass against a disabled control by reading its
    /// enabled inner StaticText. Costs no extra IPC — the whole tree is in hand.
    static func findElement(query: String, in elements: [ParsedElement]) -> FoundElement? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let matches = elements.filter { element in
            element.frame.w > 0 && element.frame.h > 0
                && matchesQuery(element: element, query: trimmed)
        }
        guard let first = matches.first else { return nil }
        return toFound(first, matchCount: matches.count)
    }

    private static func toFound(_ e: ParsedElement, matchCount: Int) -> FoundElement {
        FoundElement(
            type: e.type, label: e.label, identifier: e.identifier, value: e.value,
            centerX: e.frame.x + e.frame.w / 2,
            centerY: e.frame.y + e.frame.h / 2,
            frame: e.frame, enabled: e.enabled,
            matchCount: matchCount,
            hittable: nil
        )
    }

    /// Authoritative hittability check via XCUIElement.isHittable.
    ///
    /// Pure debugDescription parse order is not a reliable z-order proxy — decorative
    /// system overlays (e.g. Settings' dimming layer) appear later in the tree yet
    /// don't block taps. XCUITest's isHittable evaluates frame, occlusion, alpha,
    /// transforms, and user-interaction settings in one step.
    ///
    /// Returns the resolved hittability and the wall-clock duration of the check so
    /// callers can decide whether to log a slow-path diagnostic. Resolution uses a
    /// typed scope (`app.buttons`, `app.cells`, …) when the parsed type maps to a
    /// first-class query — this is materially faster than `descendants(.any)` on
    /// dense trees. NSPredicate format args are used so label/identifier strings
    /// containing quotes or percent signs cannot inject predicate syntax.
    static func checkHittability(
        for element: FoundElement,
        in app: XCUIApplication
    ) -> (hittable: Bool, duration: TimeInterval) {
        let start = Date()
        let hittable = resolveIsHittable(
            label: element.label,
            identifier: element.identifier,
            parsedType: element.type,
            in: app
        )
        return (hittable, Date().timeIntervalSince(start))
    }

    private static func resolveIsHittable(
        label: String,
        identifier: String,
        parsedType: String,
        in app: XCUIApplication
    ) -> Bool {
        let scope = typedQuery(for: parsedType, in: app) ?? app.descendants(matching: .any)
        let element: XCUIElement
        if !identifier.isEmpty {
            element = scope.matching(
                NSPredicate(format: "identifier == %@", identifier)
            ).firstMatch
        } else if !label.isEmpty {
            element = scope.matching(
                NSPredicate(format: "label == %@", label)
            ).firstMatch
        } else {
            return false
        }

        var hittable = false
        let exception = catchObjCException {
            hittable = element.exists && element.isHittable
        }
        if exception != nil {
            return false
        }
        return hittable
    }

    private static func typedQuery(for parsedType: String, in app: XCUIApplication) -> XCUIElementQuery? {
        switch parsedType {
        case "button": return app.buttons
        case "cell": return app.cells
        case "staticText": return app.staticTexts
        case "textField": return app.textFields
        case "secureTextField": return app.secureTextFields
        case "searchField": return app.searchFields
        case "switch": return app.switches
        case "image": return app.images
        case "icon": return app.icons
        case "link": return app.links
        case "navigationBar": return app.navigationBars
        case "tabBar": return app.tabBars
        case "toolbar": return app.toolbars
        case "table": return app.tables
        case "tableRow": return app.tableRows
        case "scrollView": return app.scrollViews
        case "collectionView": return app.collectionViews
        case "slider": return app.sliders
        case "stepper": return app.steppers
        case "picker": return app.pickers
        case "segmentedControl": return app.segmentedControls
        case "menu": return app.menus
        case "menuItem": return app.menuItems
        case "alert": return app.alerts
        case "sheet": return app.sheets
        case "dialog": return app.dialogs
        case "popover": return app.popovers
        case "webView": return app.webViews
        case "datePicker": return app.datePickers
        case "textView": return app.textViews
        case "activityIndicator": return app.activityIndicators
        case "progressIndicator": return app.progressIndicators
        case "pageIndicator": return app.pageIndicators
        case "map": return app.maps
        default: return nil
        }
    }

    private static func matchesQuery(element: ParsedElement, query: String) -> Bool {
        if query.hasPrefix("#") {
            let id = String(query.dropFirst())
            return element.identifier == id
        } else if let colonIndex = query.firstIndex(of: ":") {
            let prefix = String(query[query.startIndex..<colonIndex])
            let value = String(query[query.index(after: colonIndex)...])
            let valueMatches = element.label == value || element.identifier == value
            guard valueMatches else { return false }
            // Verify element type matches the query prefix
            guard let expectedType = queryPrefixToType[prefix] else { return false }
            return element.type == expectedType
        } else {
            return element.label == query || element.identifier == query
        }
    }

    /// Maps query prefixes to debugDescription type names.
    private static let queryPrefixToType: [String: String] = [
        "button": "button",
        "text": "staticText",
        "textField": "textField",
        "secureTextField": "secureTextField",
        "searchField": "searchField",
        "switch": "switch",
        "cell": "cell",
        "image": "image",
        "nav": "navigationBar",
        "alert": "alert",
        "link": "link",
        "icon": "icon",
        "toggle": "toggle",
        "slider": "slider",
        "stepper": "stepper",
        "picker": "picker",
        "segmentedControl": "segmentedControl",
        "menu": "menu",
        "menuItem": "menuItem",
        "scrollView": "scrollView",
        "webView": "webView",
        "datePicker": "datePicker",
        "textView": "textView",
    ]

    // MARK: - Line Parsing

    private static let knownTypes: Set<String> = [
        "Application", "Window", "Other", "Button", "StaticText",
        "TextField", "SecureTextField", "SearchField", "Switch", "Toggle",
        "Cell", "Image", "NavigationBar", "TabBar", "Tab", "Toolbar",
        "Table", "TableRow", "ScrollView", "Link", "Slider", "Stepper",
        "Picker", "SegmentedControl", "Alert", "Sheet", "Dialog",
        "Menu", "MenuItem", "MenuBar", "MenuBarItem", "WebView",
        "Icon", "Keyboard", "Key", "Group", "Outline", "OutlineRow",
        "CollectionView", "PageIndicator", "ProgressIndicator",
        "ActivityIndicator", "DatePicker", "TextView", "Popover",
        "RadioButton", "RadioGroup", "CheckBox", "ComboBox",
        "DisclosureTriangle", "PopUpButton", "MenuButton", "ToolbarButton",
        "StatusBar", "Map", "Grid", "Handle", "ColorWell", "LevelIndicator",
        "SplitGroup", "Splitter", "LayoutArea", "LayoutItem", "Browser",
        "Ruler", "RulerMarker", "Matte", "HelpTag", "DockItem"
    ]

    static func parseLines(_ description: String) -> [ParsedElement] {
        var results: [ParsedElement] = []
        let lines = description.components(separatedBy: "\n")

        for line in lines {
            guard let parsed = parseLine(line) else { continue }
            results.append(parsed)
        }
        return results
    }

    /// Parse a single debugDescription line into a ParsedElement.
    /// Format examples:
    ///   "    Button, 0x1234, {{16.0, 62.0}, {44.0, 44.0}}, identifier: 'BackButton', label: 'Settings'"
    ///   "      Other, 0x5678, {{0.0, 0.0}, {402.0, 874.0}}"
    ///   "        StaticText, 0x9abc, {{170.0, 73.7}, {62.0, 20.7}}, label: 'General', Disabled"
    ///   " →Application, 0x1234, pid: 54830, label: 'Settings'"
    private static func parseLine(_ line: String) -> ParsedElement? {
        // Calculate depth from leading spaces (each level = 4 spaces, or 2 for the root "→")
        let trimmed = line.replacingOccurrences(of: "→", with: " ")
        let stripped = trimmed.trimmingCharacters(in: .init(charactersIn: " "))
        guard !stripped.isEmpty else { return nil }

        let leadingSpaces = trimmed.prefix(while: { $0 == " " }).count
        let depth = leadingSpaces / 4

        // Extract element type from the start of the line (e.g., "Button," or "Window (Main),")
        guard let commaIndex = stripped.firstIndex(where: { $0 == "," || $0 == " " }),
              commaIndex > stripped.startIndex else { return nil }
        let rawType = String(stripped[..<commaIndex])
        guard knownTypes.contains(rawType) else { return nil }
        let elementType = rawType

        // Extract frame: {{x, y}, {w, h}}
        var x = 0.0, y = 0.0, w = 0.0, h = 0.0
        if let frameStart = stripped.range(of: "{{"),
           let frameEnd = stripped.range(of: "}}") {
            let frameStr = String(stripped[frameStart.lowerBound..<frameEnd.upperBound])
            let numbers = frameStr
                .replacingOccurrences(of: "{", with: "")
                .replacingOccurrences(of: "}", with: "")
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .compactMap { Double($0) }
            if numbers.count >= 4 {
                x = numbers[0]; y = numbers[1]; w = numbers[2]; h = numbers[3]
            }
        }

        // Extract identifier and label using safe extraction
        let identifier = extractQuotedValue(from: stripped, key: "identifier: '")
        let label = extractQuotedValue(from: stripped, key: "label: '")

        // Extract value (unquoted)
        var value = ""
        if let valueRange = stripped.range(of: "value: ") {
            let afterValue = String(stripped[valueRange.upperBound...])
            value = String(afterValue.prefix(while: { $0 != "," && $0 != "\n" }))
                .trimmingCharacters(in: .whitespaces)
        }

        // Check enabled: the `Disabled` flag is a standalone comma-separated
        // token, not the substring "Disabled" inside a quoted label like
        // 'Wi-Fi Disabled' or 'a, Disabled, b' (A12).
        let enabled = !hasDisabledFlag(stripped)

        // Normalize type name to camelCase matching ElementResolver
        let normalizedType = normalizeTypeName(elementType)

        return ParsedElement(
            type: normalizedType,
            label: label,
            identifier: identifier,
            value: value,
            frame: (x, y, w, h),
            enabled: enabled,
            depth: depth,
            children: []
        )
    }

    // MARK: - Tree Building

    private static func buildTree(from elements: [ParsedElement], maxDepth: Int) -> [String: Any]? {
        guard !elements.isEmpty else { return nil }

        // Build tree using depth information
        var stack: [(depth: Int, node: [String: Any])] = []

        for element in elements {
            let node = elementToDict(element)

            while let last = stack.last, last.depth >= element.depth {
                stack.removeLast()
                if var parent = stack.last {
                    var children = parent.node["children"] as? [[String: Any]] ?? []
                    children.append(last.node)
                    parent.node["children"] = children
                    stack[stack.count - 1] = parent
                }
            }

            if element.depth <= maxDepth {
                stack.append((element.depth, node))
            }
        }

        // Collapse remaining stack
        while stack.count > 1 {
            let last = stack.removeLast()
            if var parent = stack.last {
                var children = parent.node["children"] as? [[String: Any]] ?? []
                children.append(last.node)
                parent.node["children"] = children
                stack[stack.count - 1] = parent
            }
        }

        return stack.first?.node
    }

    private static func buildCompactTree(from elements: [ParsedElement], maxDepth: Int) -> [String: Any]? {
        // Build full tree first, then collapse passthrough nodes
        guard var tree = buildTree(from: elements, maxDepth: maxDepth) else { return nil }
        collapsePassthrough(&tree)
        return tree
    }

    private static let passthroughTypes: Set<String> = ["other", "group", "window"]

    private static func collapsePassthrough(_ node: inout [String: Any]) {
        guard var children = node["children"] as? [[String: Any]] else { return }

        // Recursively collapse children first
        for i in children.indices {
            collapsePassthrough(&children[i])
        }

        // If this is a passthrough node with exactly 1 child, replace with child
        let type = node["type"] as? String ?? ""
        let label = node["label"] as? String ?? ""
        let identifier = node["identifier"] as? String ?? ""
        if passthroughTypes.contains(type) && label.isEmpty && identifier.isEmpty && children.count == 1 {
            node = children[0]
            return
        }

        node["children"] = children
    }

    // MARK: - Actionable List

    private static let actionableTypes: Set<String> = [
        "button", "link", "textField", "secureTextField", "searchField",
        "switch", "toggle", "slider", "stepper", "picker",
        "segmentedControl", "menuItem", "tab", "cell", "icon"
    ]

    private static let excludedTypes: Set<String> = [
        "other", "window", "application", "group"
    ]

    /// The single membership rule for the actionable list. Alias resolution walks
    /// the same predicate to recover element N, so "which elements are in the
    /// list" cannot be answered differently by the two paths — a divergence would
    /// silently shift every alias by the number of disagreeing elements.
    static func isActionable(_ element: ParsedElement) -> Bool {
        if actionableTypes.contains(element.type) { return true }
        return !element.identifier.isEmpty && !excludedTypes.contains(element.type)
    }

    /// The membership rule *plus* the depth bound — the whole predicate behind "is
    /// this one of the elements `@eN` numbers". Three walks apply it: the list
    /// itself, alias resolution, and SU4's list detection.
    ///
    /// Sharing the predicate is what keeps them from drifting on *which elements
    /// count*; the depth they pass is a separate question each caller answers (alias
    /// resolution from `ElementSnapshot.depth`, list detection always at
    /// `defaultActionableDepth`), and list detection narrows further to rows that are
    /// framed and on screen.
    static func isActionable(_ element: ParsedElement, withinDepth maxDepth: Int) -> Bool {
        element.depth <= maxDepth && isActionable(element)
    }

    private static func collectActionable(from elements: [ParsedElement], maxDepth: Int) -> [[String: Any]] {
        elements
            .filter { isActionable($0, withinDepth: maxDepth) }
            .map(elementToDict)
    }

    // MARK: - Summary

    private static let summaryTypes: Set<String> = [
        "button", "link", "textField", "secureTextField", "searchField",
        "switch", "toggle", "slider", "stepper", "picker",
        "segmentedControl", "menuItem", "tab", "cell",
        "staticText", "image", "navigationBar", "tabBar", "alert", "icon"
    ]

    private static func buildSummary(from elements: [ParsedElement]) -> [String: Any] {
        var counts: [String: Int] = [:]
        var total = 0
        for element in elements {
            if summaryTypes.contains(element.type) {
                counts[element.type, default: 0] += 1
                total += 1
            }
        }
        return ["counts": counts, "total": total]
    }

    // MARK: - Helpers

    private static func elementToDict(_ element: ParsedElement) -> [String: Any] {
        var node: [String: Any] = [
            "type": element.type,
            "label": element.label,
            "identifier": element.identifier,
            "frame": [
                "x": element.frame.x,
                "y": element.frame.y,
                "width": element.frame.w,
                "height": element.frame.h
            ],
            "enabled": element.enabled
        ]
        if !element.value.isEmpty {
            node["value"] = element.value
        }
        // Generate query string (bare label preferred for speed)
        if !element.label.isEmpty {
            node["query"] = element.label
        } else if !element.identifier.isEmpty {
            node["query"] = "#\(element.identifier)"
        }
        return node
    }

    /// Whether the debugDescription line carries the bare `Disabled` flag —
    /// a standalone comma-separated token — rather than "Disabled" appearing
    /// inside a quoted label. Commas inside a quoted value must not split, so a
    /// `'` opens a value that is consumed through its matching close (the `'`
    /// followed by `,` or end-of-line, matching `extractQuotedValue`). Toggling
    /// on every `'` would desync on an interior apostrophe (`It's, fine`).
    static func hasDisabledFlag(_ stripped: String) -> Bool {
        var token = ""
        var i = stripped.startIndex
        while i < stripped.endIndex {
            let ch = stripped[i]
            if ch == "'" {
                // Consume the whole quoted value (apostrophes/commas and all)
                // into the current token, which is never a bare flag.
                token.append(ch)
                i = stripped.index(after: i)
                while i < stripped.endIndex {
                    let c = stripped[i]
                    token.append(c)
                    i = stripped.index(after: i)
                    if c == "'" && (i == stripped.endIndex || stripped[i] == ",") { break }
                }
            } else if ch == "," {
                if token.trimmingCharacters(in: .whitespaces) == "Disabled" { return true }
                token = ""
                i = stripped.index(after: i)
            } else {
                token.append(ch)
                i = stripped.index(after: i)
            }
        }
        return token.trimmingCharacters(in: .whitespaces) == "Disabled"
    }

    /// Safely extract a single-quoted value after a key like "label: '".
    /// Returns empty string if the key is not found or the quote is unclosed
    /// (which happens when debugDescription truncates long lines).
    private static func extractQuotedValue(from text: String, key: String) -> String {
        guard let keyRange = text.range(of: key) else { return "" }
        let after = text[keyRange.upperBound...]
        // The value ends at the closing quote: the `'` followed by the attribute
        // delimiter `,` or the end of the line. An apostrophe *inside* the value
        // (`User's Name`) is followed by a letter/space, not `,`, so it isn't
        // mistaken for the close and the label is no longer truncated (A11).
        var idx = after.startIndex
        while idx < after.endIndex {
            if after[idx] == "'" {
                let next = after.index(after: idx)
                if next == after.endIndex || after[next] == "," {
                    return String(after[after.startIndex..<idx])
                }
            }
            idx = after.index(after: idx)
        }
        return ""
    }

    private static func normalizeTypeName(_ raw: String) -> String {
        switch raw {
        case "Application": return "application"
        case "Window": return "window"
        case "Other": return "other"
        case "Group": return "group"
        case "Button": return "button"
        case "StaticText": return "staticText"
        case "TextField": return "textField"
        case "SecureTextField": return "secureTextField"
        case "SearchField": return "searchField"
        case "Switch": return "switch"
        case "Toggle": return "toggle"
        case "Cell": return "cell"
        case "Image": return "image"
        case "Icon": return "icon"
        case "NavigationBar": return "navigationBar"
        case "TabBar": return "tabBar"
        case "Tab": return "tab"
        case "Toolbar": return "toolbar"
        case "Table": return "table"
        case "TableRow": return "tableRow"
        case "ScrollView": return "scrollView"
        case "Link": return "link"
        case "Slider": return "slider"
        case "Stepper": return "stepper"
        case "Picker": return "picker"
        case "SegmentedControl": return "segmentedControl"
        case "Alert": return "alert"
        case "Sheet": return "sheet"
        case "Dialog": return "dialog"
        case "Menu": return "menu"
        case "MenuItem": return "menuItem"
        case "WebView": return "webView"
        case "Keyboard": return "keyboard"
        case "Key": return "key"
        case "Popover": return "popover"
        case "CollectionView": return "collectionView"
        case "PageIndicator": return "pageIndicator"
        case "ProgressIndicator": return "progressIndicator"
        case "ActivityIndicator": return "activityIndicator"
        case "DatePicker": return "datePicker"
        case "TextView": return "textView"
        case "Map": return "map"
        case "Grid": return "grid"
        case "Handle": return "handle"
        case "StatusBar": return "statusBar"
        default: return raw.prefix(1).lowercased() + raw.dropFirst()
        }
    }
}
