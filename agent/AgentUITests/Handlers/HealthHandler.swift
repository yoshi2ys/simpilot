import Foundation

final class HealthHandler {
    func handle(_ request: HTTPRequest) -> Data {
        return HTTPResponseBuilder.json(["status": "ready"])
    }
}
