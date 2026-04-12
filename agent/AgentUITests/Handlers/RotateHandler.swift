import Foundation
import XCTest

final class RotateHandler: @unchecked Sendable {
    private static let orientations: [String: UIDeviceOrientation] = [
        "portrait": .portrait,
        "portraitUpsideDown": .portraitUpsideDown,
        "landscapeLeft": .landscapeLeft,
        "landscapeRight": .landscapeRight,
    ]

    func handle(_ request: HTTPRequest) -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let raw = json["orientation"] as? String else {
            return HTTPResponseBuilder.error(
                "Missing 'orientation' in request body",
                code: "invalid_request"
            )
        }

        guard let orientation = Self.orientations[raw] else {
            let valid = Self.orientations.keys.sorted().joined(separator: ", ")
            return HTTPResponseBuilder.error(
                "Unsupported orientation: \(raw). Use: \(valid)",
                code: "invalid_args"
            )
        }

        XCUIDevice.shared.orientation = orientation
        return HTTPResponseBuilder.json(["orientation": raw])
    }
}
