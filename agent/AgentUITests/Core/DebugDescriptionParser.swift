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
        let desc = app.debugDescription
        let elements = parseLines(desc)
        guard let root = buildTree(from: elements, maxDepth: maxDepth) else {
            return [:]
        }
        return root
    }

    /// Parse debugDescription into an actionable flat list (Flat list of interactive elements).
    static func parseActionableList(from app: XCUIApplication, maxDepth: Int = 20) -> [[String: Any]] {
        let desc = app.debugDescription
        let elements = parseLines(desc)
        return collectActionable(from: elements, maxDepth: maxDepth)
    }

    /// Parse debugDescription into a summary of element counts (Element type counts).
    static func parseSummary(from app: XCUIApplication) -> [String: Any] {
        let desc = app.debugDescription
        let elements = parseLines(desc)
        return buildSummary(from: elements)
    }

    /// Parse debugDescription into a compact tree (Tree with single-child passthrough nodes collapsed).
    static func parseCompactTree(from app: XCUIApplication, maxDepth: Int = 10) -> [String: Any] {
        let desc = app.debugDescription
        let elements = parseLines(desc)
        guard let root = buildCompactTree(from: elements, maxDepth: maxDepth) else {
            return [:]
        }
        return root
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

        /// JSON-ready dict for HTTP responses. Shared by TapHandler and AssertHandler.
        var asDict: [String: Any] {
            var dict: [String: Any] = [
                "type": type,
                "label": label,
                "identifier": identifier,
                "frame": [
                    "x": frame.x, "y": frame.y,
                    "width": frame.w, "height": frame.h
                ],
                "enabled": enabled
            ]
            if !value.isEmpty {
                dict["value"] = value
            }
            return dict
        }
    }

    /// Find an element by query in the debugDescription and return its center coordinates.
    /// This bypasses XCUITest's slow element resolution (~24s) by parsing the text tree (~0.2s).
    static func findElement(query: String, in app: XCUIApplication) -> FoundElement? {
        let desc = app.debugDescription
        let elements = parseLines(desc)
        let trimmed = query.trimmingCharacters(in: .whitespaces)

        for element in elements {
            guard element.frame.w > 0 && element.frame.h > 0 else { continue }
            if matchesQuery(element: element, query: trimmed) {
                return toFound(element)
            }
        }
        return nil
    }

    private static func toFound(_ e: ParsedElement) -> FoundElement {
        FoundElement(
            type: e.type, label: e.label, identifier: e.identifier, value: e.value,
            centerX: e.frame.x + e.frame.w / 2,
            centerY: e.frame.y + e.frame.h / 2,
            frame: e.frame, enabled: e.enabled
        )
    }

    private static func matchesQuery(element: ParsedElement, query: String) -> Bool {
        if query.hasPrefix("#") {
            let id = String(query.dropFirst())
            return element.identifier == id
        } else if let colonIndex = query.firstIndex(of: ":") {
            let value = String(query[query.index(after: colonIndex)...])
            return element.label == value || element.identifier == value
        } else {
            return element.label == query || element.identifier == query
        }
    }

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

    private static func parseLines(_ description: String) -> [ParsedElement] {
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

        // Check enabled (Disabled flag)
        let enabled = !stripped.hasSuffix("Disabled") && !stripped.contains(", Disabled,")

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

    private static func collectActionable(from elements: [ParsedElement], maxDepth: Int) -> [[String: Any]] {
        var results: [[String: Any]] = []
        for element in elements where element.depth <= maxDepth {
            let isActionable = actionableTypes.contains(element.type)
            let hasIdentifier = !element.identifier.isEmpty && !excludedTypes.contains(element.type)
            if isActionable || hasIdentifier {
                results.append(elementToDict(element))
            }
        }
        return results
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

    /// Safely extract a single-quoted value after a key like "label: '".
    /// Returns empty string if the key is not found or the quote is unclosed
    /// (which happens when debugDescription truncates long lines).
    private static func extractQuotedValue(from text: String, key: String) -> String {
        guard let keyRange = text.range(of: key) else { return "" }
        let after = String(text[keyRange.upperBound...])
        guard let endQuote = after.firstIndex(of: "'") else { return "" }
        return String(after[after.startIndex..<endQuote])
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
