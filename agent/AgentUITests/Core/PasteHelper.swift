import Foundation
import XCTest

enum PasteHelper {
    /// Perform text input using the specified method. Returns (usedMethod, error).
    static func performTextInput(_ text: String, method: String, at coord: XCUICoordinate?, in app: XCUIApplication) -> (usedMethod: String, error: Data?) {
        var usedMethod = method
        switch method {
        case "type":
            app.typeText(text)

        case "paste":
            #if os(tvOS)
            return ("paste", HTTPResponseBuilder.error("paste method is not supported on tvOS", code: "unsupported_platform"))
            #else
            if let error = paste(text: text, at: coord, in: app) {
                return ("paste", error)
            }
            #endif

        case "auto":
            #if os(tvOS)
            app.typeText(text)
            usedMethod = "type"
            #else
            if app.keyboards.firstMatch.waitForExistence(timeout: 1.0) {
                app.typeText(text)
                usedMethod = "type"
            } else if let error = paste(text: text, at: coord, in: app) {
                return ("paste", error)
            } else {
                usedMethod = "paste"
            }
            #endif

        default:
            return (method, HTTPResponseBuilder.error(
                "Unknown method '\(method)'. Use 'type', 'paste', or 'auto'.",
                code: "invalid_request"
            ))
        }
        return (usedMethod, nil)
    }

    #if !os(tvOS)
    private static var pastePermissionGranted = false
    private static let pasteLabels = ["Paste", "ペースト", "Coller", "Einfügen", "Pegar", "Incolla"]
    private static let pastePredicate = NSPredicate(format: "label IN %@", pasteLabels)

    /// Paste text via UIPasteboard + edit menu. Returns error Data if paste fails, nil on success.
    static func paste(text: String, at coord: XCUICoordinate?, in app: XCUIApplication) -> Data? {
        let originalPasteboard = UIPasteboard.general.string
        defer { UIPasteboard.general.string = originalPasteboard ?? "" }
        UIPasteboard.general.string = text

        if let coord = coord {
            coord.press(forDuration: 1.0)
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 1.0)
        }

        if !pastePermissionGranted {
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            if springboard.alerts.buttons["Allow Paste"].waitForExistence(timeout: 1.0) {
                springboard.alerts.buttons["Allow Paste"].tap()
            }
            pastePermissionGranted = true
        }

        let menuItem = app.menuItems.matching(pastePredicate).firstMatch
        if menuItem.waitForExistence(timeout: 1.5) {
            menuItem.tap()
            return nil
        }

        return HTTPResponseBuilder.error(
            "Paste menu item not found. Edit menu may not have appeared.",
            code: "paste_failed"
        )
    }
    #endif
}
