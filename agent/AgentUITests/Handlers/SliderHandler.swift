import Foundation
import XCTest

final class SliderHandler: @unchecked Sendable {
    private let appManager: AppManager

    init(appManager: AppManager) {
        self.appManager = appManager
    }

    func handle(_ request: HTTPRequest) -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let value = json["value"] as? Double else {
            return HTTPResponseBuilder.error(
                "Missing or invalid 'value' in request body",
                code: "invalid_request"
            )
        }

        guard value >= 0 && value <= 1 else {
            return HTTPResponseBuilder.error(
                "value must be between 0.0 and 1.0",
                code: "invalid_request"
            )
        }

        let query = json["query"] as? String

        let app = appManager.currentApp()

        let target: XCUIElement
        if let query, !query.isEmpty {
            do {
                target = try ElementResolver.resolve(query: query, in: app)
            } catch ElementResolverError.elementNotFound(let msg) {
                return HTTPResponseBuilder.error(msg, code: "element_not_found")
            } catch ElementResolverError.invalidQuery(let msg) {
                return HTTPResponseBuilder.error(msg, code: "invalid_query")
            } catch {
                return HTTPResponseBuilder.error(error.localizedDescription, code: "slider_failed", status: 500)
            }
        } else {
            // No query — find the first slider in the app
            let slider = app.sliders.firstMatch
            guard slider.waitForExistence(timeout: 2) else {
                return HTTPResponseBuilder.error(
                    "No slider found in the current view",
                    code: "element_not_found"
                )
            }
            target = slider
        }

        let failure = catchObjCException {
            target.adjust(toNormalizedSliderPosition: CGFloat(value))
        }
        if let failure {
            return HTTPResponseBuilder.error(
                "Slider adjustment failed: \(failure)",
                code: "slider_failed",
                status: 500
            )
        }

        var data: [String: Any] = [
            "action": "slider",
            "value": value,
            "element": ElementResolver.describe(target),
        ]
        if let query { data["query"] = query }

        return HTTPResponseBuilder.json(data)
    }
}
