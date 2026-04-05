import Foundation
import XCTest

final class ScreenshotHandler {
    func handle(_ request: HTTPRequest) -> Data {
        let filePath = request.queryParams["file"]

        let screenshot = XCUIScreen.main.screenshot()
        let pngData = screenshot.pngRepresentation

        if let filePath = filePath, !filePath.isEmpty {
            do {
                try pngData.write(to: URL(fileURLWithPath: filePath))
                return HTTPResponseBuilder.json(["file": filePath, "size": pngData.count])
            } catch {
                return HTTPResponseBuilder.error(
                    "Failed to write screenshot: \(error.localizedDescription)",
                    code: "write_failed",
                    status: 500
                )
            }
        } else {
            let base64 = pngData.base64EncodedString()
            return HTTPResponseBuilder.json(["base64": base64, "format": "png", "size": pngData.count])
        }
    }
}
