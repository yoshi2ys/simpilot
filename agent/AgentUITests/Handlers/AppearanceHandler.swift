import Foundation
import XCTest

final class AppearanceHandler {
    func handleGet(_ request: HTTPRequest) -> Data {
        let current = XCUIDevice.shared.appearance
        let value: String
        switch current {
        case .dark: value = "dark"
        case .light: value = "light"
        case .unspecified: value = "unspecified"
        @unknown default: value = "unknown"
        }
        return HTTPResponseBuilder.json(["appearance": value])
    }

    func handleSet(_ request: HTTPRequest) -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let mode = json["mode"] as? String else {
            return HTTPResponseBuilder.error("Missing or invalid 'mode' (light, dark, unspecified)", code: "invalid_request")
        }

        switch mode {
        case "dark":
            XCUIDevice.shared.appearance = .dark
        case "light":
            XCUIDevice.shared.appearance = .light
        case "unspecified":
            XCUIDevice.shared.appearance = .unspecified
        default:
            return HTTPResponseBuilder.error("Invalid mode '\(mode)'. Use: light, dark, unspecified", code: "invalid_request")
        }

        return HTTPResponseBuilder.json(["appearance": mode])
    }
}
