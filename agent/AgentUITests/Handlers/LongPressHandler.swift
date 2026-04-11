import Foundation
import XCTest

final class LongPressHandler: @unchecked Sendable {
    /// Matches iOS `UILongPressGestureRecognizer`'s 0.5s default and the
    /// commonly-tuned 1.0s. XCUITest long-presses below this threshold are
    /// brittle in Settings-style chrome; 0.8s clears a Springboard context
    /// menu reliably without feeling sluggish to record.
    static let defaultDurationSeconds: Double = 0.8

    private let appManager: AppManager

    init(appManager: AppManager) {
        self.appManager = appManager
    }

    func handle(_ request: HTTPRequest) -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let query = json["query"] as? String else {
            return HTTPResponseBuilder.error(
                "Missing or invalid 'query' in request body",
                code: "invalid_request"
            )
        }

        // XCUITest treats `press(forDuration: 0.0)` as a no-op; we deliberately
        // honor the client's request rather than rejecting it (decision: docs
        // note the behavior instead of inventing a validation rule).
        let duration = (json["duration"] as? Double) ?? Self.defaultDurationSeconds

        let app = appManager.currentApp()
        let resolution = TapHandler.resolveAndTap(
            query: query,
            wait: TapHandler.parseWaitArgs(from: json),
            gesture: .longPress(duration: duration),
            in: app
        )
        return TapHandler.responseData(from: resolution)
    }
}
