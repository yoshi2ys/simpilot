import Foundation
import XCTest

final class AlertHandler: @unchecked Sendable {
    func handle(_ request: HTTPRequest) -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let action = json["action"] as? String,
              action == "accept" || action == "dismiss" else {
            return HTTPResponseBuilder.error(
                "Missing or invalid 'action'. Use 'accept' or 'dismiss'.",
                code: "invalid_request"
            )
        }

        let timeoutSeconds = (json["timeout"] as? Double) ?? 0.0

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch

        if timeoutSeconds > 0 {
            guard alert.waitForExistence(timeout: timeoutSeconds) else {
                return HTTPResponseBuilder.json([
                    "action": action,
                    "found": false,
                    "message": "No system alert found within \(timeoutSeconds)s"
                ] as [String: Any])
            }
        } else {
            guard alert.exists else {
                return HTTPResponseBuilder.json([
                    "action": action,
                    "found": false,
                    "message": "No system alert found"
                ] as [String: Any])
            }
        }

        let buttons = alert.buttons
        let count = buttons.count
        guard count > 0 else {
            return HTTPResponseBuilder.json([
                "action": action,
                "found": true,
                "message": "Alert found but has no buttons"
            ] as [String: Any])
        }

        // "accept" taps the last button (typically "Allow" / "OK"),
        // "dismiss" taps the first button (typically "Don't Allow" / "Cancel").
        let target = (action == "accept") ? buttons.element(boundBy: count - 1) : buttons.element(boundBy: 0)
        let label = target.label
        target.tap()

        return HTTPResponseBuilder.json([
            "action": action,
            "found": true,
            "button": label
        ] as [String: Any])
    }
}
