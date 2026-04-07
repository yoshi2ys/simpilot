import Foundation
import XCTest

final class ClipboardHandler: @unchecked Sendable {

    func handleGet(_ request: HTTPRequest) -> Data {
        #if os(tvOS)
        return HTTPResponseBuilder.error("Clipboard is not supported on tvOS", code: "unsupported_platform")
        #else
        let text = UIPasteboard.general.string
        return HTTPResponseBuilder.json(["text": text as Any])
        #endif
    }

    func handleSet(_ request: HTTPRequest) -> Data {
        #if os(tvOS)
        return HTTPResponseBuilder.error("Clipboard is not supported on tvOS", code: "unsupported_platform")
        #else
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let text = json["text"] as? String else {
            return HTTPResponseBuilder.error("Missing 'text' field", code: "invalid_request")
        }

        UIPasteboard.general.string = text
        return HTTPResponseBuilder.json(["text": text])
        #endif
    }
}
