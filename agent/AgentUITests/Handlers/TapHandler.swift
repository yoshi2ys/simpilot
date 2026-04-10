import Foundation
import XCTest

final class TapHandler: @unchecked Sendable {
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

        let app = appManager.currentApp()

        // Fast path: resolve via debugDescription parsing (~0.2s) + coordinate tap
        #if !os(tvOS)
        if let found = DebugDescriptionParser.findElement(query: query, in: app) {
            let coordTapFailed = catchObjCException {
                let coord = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
                    .withOffset(CGVector(dx: found.centerX, dy: found.centerY))
                coord.tap()
            }

            if coordTapFailed == nil {
                return HTTPResponseBuilder.json([
                    "element": [
                        "type": found.type,
                        "label": found.label,
                        "identifier": found.identifier,
                        "frame": [
                            "x": found.frame.x, "y": found.frame.y,
                            "width": found.frame.w, "height": found.frame.h
                        ],
                        "enabled": found.enabled
                    ] as [String: Any]
                ])
            }
            // Coordinate tap failed (e.g. visionOS spatial windows) — fall through to element.tap()
        } else {
            // Element not found in debugDescription.
            // For bare and #identifier queries, this is authoritative — ElementResolver
            // would return a phantom proxy (0x0 frame) instead of an error.
            // Only typed queries (button:, text:, etc.) need the ElementResolver fallback.
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            if !trimmed.contains(":") {
                return HTTPResponseBuilder.error("Element not found for query: \(query)", code: "element_not_found")
            }
        }
        #endif

        // Fallback: XCUITest element resolution + native tap (typed queries only on this path)
        do {
            let element = try ElementResolver.resolve(query: query, in: app)
            #if os(tvOS)
            XCUIRemote.shared.press(.select)
            #else
            element.tap()
            #endif
            return HTTPResponseBuilder.json(["element": ElementResolver.describe(element)])
        } catch {
            return HTTPResponseBuilder.error("Element not found for query: \(query)", code: "element_not_found")
        }
    }
}
