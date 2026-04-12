import Foundation
import XCTest

enum ElementResolverError: Error {
    case invalidQuery(String)
    case elementNotFound(String)
}


enum ElementResolver {
    /// Resolve a query string to an XCUIElement.
    /// Formats:
    ///   #identifier           -> descendants["identifier"]
    ///   button:Login          -> app.buttons["Login"]
    ///   text:Hello            -> app.staticTexts["Hello"]
    ///   textField:Email       -> app.textFields["Email"]
    ///   secureTextField:Pass  -> app.secureTextFields["Pass"]
    ///   switch:Dark Mode      -> app.switches["Dark Mode"]
    ///   cell:2                -> app.cells.element(boundBy: 2)
    ///   image:Logo            -> app.images["Logo"]
    ///   nav:Settings          -> app.navigationBars["Settings"]
    ///   tab:Home              -> app.tabBars.buttons["Home"]
    ///   alert:Error           -> app.alerts["Error"]
    ///   link:Label            -> app.links["Label"]
    ///   icon:Logo             -> app.icons["Logo"]
    ///   toggle:Dark Mode      -> app.toggles["Dark Mode"]
    ///   slider:Volume         -> app.sliders["Volume"]
    ///   stepper:Quantity      -> app.steppers["Quantity"]
    ///   picker:Country        -> app.pickers["Country"]
    ///   segmentedControl:Tab  -> app.segmentedControls["Tab"]
    ///   menu:File             -> app.menus["File"]
    ///   menuItem:Copy         -> app.menuItems["Copy"]
    ///   scrollView:Content    -> app.scrollViews["Content"]
    ///   webView:Browser       -> app.webViews["Browser"]
    ///   datePicker:Birthday   -> app.datePickers["Birthday"]
    ///   textView:Notes        -> app.textViews["Notes"]
    ///   Login (no prefix)     -> search descendants by label/identifier

    /// Look up an element by query without waiting for existence.
    /// Use this when you need the XCUIElement proxy for custom waiting logic.
    static func lookup(query: String, in app: XCUIApplication) throws -> XCUIElement {
        let result = try lookupElement(query: query, in: app)
        return result.element
    }

    /// Resolve a query string to an XCUIElement, waiting for it to exist.
    static func resolve(query: String, in app: XCUIApplication) throws -> XCUIElement {
        let result = try lookupElement(query: query, in: app)

        // Only wait for typed queries (button:, text:, etc.) — they resolve fast.
        // For #identifier and bare queries, skip waiting: descendants(matching: .any)
        // can take 20+ seconds on complex apps. If the element doesn't exist,
        // the ObjC exception catcher in Router.safeExecute handles it.
        if result.queryCollection != nil {
            guard result.element.waitForExistence(timeout: 2) else {
                throw ElementResolverError.elementNotFound("Element not found for query: \(result.trimmed)")
            }
        }

        return result.element
    }

    // MARK: - Private

    private struct LookupResult {
        let element: XCUIElement
        let queryCollection: XCUIElementQuery?
        let trimmed: String
    }

    private static func lookupElement(query: String, in app: XCUIApplication) throws -> LookupResult {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw ElementResolverError.invalidQuery("Empty query")
        }

        let element: XCUIElement
        var queryCollection: XCUIElementQuery?

        if trimmed.hasPrefix("#") {
            let identifier = String(trimmed.dropFirst())
            let predicate = NSPredicate(format: "identifier == %@", identifier)
            element = app.descendants(matching: .any).matching(predicate).firstMatch
            queryCollection = nil
        } else if let colonIndex = trimmed.firstIndex(of: ":") {
            let prefix = String(trimmed[trimmed.startIndex..<colonIndex])
            let value = String(trimmed[trimmed.index(after: colonIndex)...])
            let predicate = NSPredicate(format: "label == %@ OR identifier == %@", value, value)

            switch prefix {
            case "button":
                element = app.buttons[value]
                queryCollection = app.buttons.matching(predicate)
            case "text":
                element = app.staticTexts[value]
                queryCollection = app.staticTexts.matching(predicate)
            case "textField":
                element = app.textFields[value]
                queryCollection = app.textFields.matching(predicate)
            case "secureTextField":
                element = app.secureTextFields[value]
                queryCollection = app.secureTextFields.matching(predicate)
            case "searchField":
                element = app.searchFields[value]
                queryCollection = app.searchFields.matching(predicate)
            case "switch":
                element = app.switches[value]
                queryCollection = app.switches.matching(predicate)
            case "cell":
                if let index = Int(value) {
                    element = app.cells.element(boundBy: index)
                    // Index-based access: no collection (count is always 1)
                } else {
                    element = app.cells[value]
                    queryCollection = app.cells.matching(predicate)
                }
            case "image":
                element = app.images[value]
                queryCollection = app.images.matching(predicate)
            case "nav":
                element = app.navigationBars[value]
                queryCollection = app.navigationBars.matching(predicate)
            case "tab":
                element = app.tabBars.buttons[value]
                queryCollection = app.tabBars.buttons.matching(predicate)
            case "alert":
                element = app.alerts[value]
                queryCollection = app.alerts.matching(predicate)
            case "link":
                element = app.links[value]
                queryCollection = app.links.matching(predicate)
            case "icon":
                element = app.icons[value]
                queryCollection = app.icons.matching(predicate)
            case "toggle":
                element = app.toggles[value]
                queryCollection = app.toggles.matching(predicate)
            case "slider":
                element = app.sliders[value]
                queryCollection = app.sliders.matching(predicate)
            case "stepper":
                element = app.steppers[value]
                queryCollection = app.steppers.matching(predicate)
            case "picker":
                element = app.pickers[value]
                queryCollection = app.pickers.matching(predicate)
            case "segmentedControl":
                element = app.segmentedControls[value]
                queryCollection = app.segmentedControls.matching(predicate)
            case "menu":
                element = app.menus[value]
                queryCollection = app.menus.matching(predicate)
            case "menuItem":
                element = app.menuItems[value]
                queryCollection = app.menuItems.matching(predicate)
            case "scrollView":
                element = app.scrollViews[value]
                queryCollection = app.scrollViews.matching(predicate)
            case "webView":
                element = app.webViews[value]
                queryCollection = app.webViews.matching(predicate)
            case "datePicker":
                element = app.datePickers[value]
                queryCollection = app.datePickers.matching(predicate)
            case "textView":
                element = app.textViews[value]
                queryCollection = app.textViews.matching(predicate)
            default:
                throw ElementResolverError.invalidQuery("Unknown element type prefix: \(prefix)")
            }
        } else {
            // No prefix — search all descendants by label or identifier
            let predicate = NSPredicate(format: "label == %@ OR identifier == %@", trimmed, trimmed)
            element = app.descendants(matching: .any).matching(predicate).firstMatch
            queryCollection = nil
        }

        return LookupResult(element: element, queryCollection: queryCollection, trimmed: trimmed)
    }

    /// Return a dictionary describing the element for JSON responses.
    static func describe(_ element: XCUIElement) -> [String: Any] {
        return [
            "type": elementTypeName(element.elementType),
            "label": element.label,
            "identifier": element.identifier,
            "value": element.value as Any? ?? NSNull(),
            "frame": [
                "x": element.frame.origin.x,
                "y": element.frame.origin.y,
                "width": element.frame.size.width,
                "height": element.frame.size.height
            ],
            "enabled": element.isEnabled,
            "selected": element.isSelected
        ]
    }

    static func elementTypeName(_ type: XCUIElement.ElementType) -> String {
        switch type {
        case .any: return "any"
        case .other: return "other"
        case .application: return "application"
        case .group: return "group"
        case .window: return "window"
        case .sheet: return "sheet"
        case .drawer: return "drawer"
        case .alert: return "alert"
        case .dialog: return "dialog"
        case .button: return "button"
        case .radioButton: return "radioButton"
        case .radioGroup: return "radioGroup"
        case .checkBox: return "checkBox"
        case .disclosureTriangle: return "disclosureTriangle"
        case .popUpButton: return "popUpButton"
        case .comboBox: return "comboBox"
        case .menuButton: return "menuButton"
        case .toolbarButton: return "toolbarButton"
        case .popover: return "popover"
        case .keyboard: return "keyboard"
        case .key: return "key"
        case .navigationBar: return "navigationBar"
        case .tabBar: return "tabBar"
        case .tabGroup: return "tabGroup"
        case .toolbar: return "toolbar"
        case .statusBar: return "statusBar"
        case .table: return "table"
        case .tableRow: return "tableRow"
        case .tableColumn: return "tableColumn"
        case .outline: return "outline"
        case .outlineRow: return "outlineRow"
        case .browser: return "browser"
        case .collectionView: return "collectionView"
        case .slider: return "slider"
        case .pageIndicator: return "pageIndicator"
        case .progressIndicator: return "progressIndicator"
        case .activityIndicator: return "activityIndicator"
        case .segmentedControl: return "segmentedControl"
        case .picker: return "picker"
        case .pickerWheel: return "pickerWheel"
        case .switch: return "switch"
        case .toggle: return "toggle"
        case .link: return "link"
        case .image: return "image"
        case .icon: return "icon"
        case .searchField: return "searchField"
        case .scrollView: return "scrollView"
        case .scrollBar: return "scrollBar"
        case .staticText: return "staticText"
        case .textField: return "textField"
        case .secureTextField: return "secureTextField"
        case .datePicker: return "datePicker"
        case .textView: return "textView"
        case .menu: return "menu"
        case .menuItem: return "menuItem"
        case .menuBar: return "menuBar"
        case .menuBarItem: return "menuBarItem"
        case .map: return "map"
        case .webView: return "webView"
        case .incrementArrow: return "incrementArrow"
        case .decrementArrow: return "decrementArrow"
        case .timeline: return "timeline"
        case .ratingIndicator: return "ratingIndicator"
        case .valueIndicator: return "valueIndicator"
        case .splitGroup: return "splitGroup"
        case .splitter: return "splitter"
        case .relevanceIndicator: return "relevanceIndicator"
        case .colorWell: return "colorWell"
        case .helpTag: return "helpTag"
        case .matte: return "matte"
        case .dockItem: return "dockItem"
        case .ruler: return "ruler"
        case .rulerMarker: return "rulerMarker"
        case .grid: return "grid"
        case .levelIndicator: return "levelIndicator"
        case .cell: return "cell"
        case .layoutArea: return "layoutArea"
        case .layoutItem: return "layoutItem"
        case .handle: return "handle"
        case .stepper: return "stepper"
        case .tab: return "tab"
        case .touchBar: return "touchBar"
        case .statusItem: return "statusItem"
        @unknown default: return "unknown(\(type.rawValue))"
        }
    }
}
