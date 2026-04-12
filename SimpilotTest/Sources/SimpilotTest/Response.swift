import Foundation

enum Response {
    /// Parse raw HTTP response data into a JSON dictionary.
    static func parse(_ data: Data) throws -> [String: Any] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if let str = String(data: data, encoding: .utf8) {
                return ["success": true, "data": str]
            }
            return ["success": true, "data": NSNull()]
        }
        return json
    }

    /// Check that the response indicates success; throw on failure.
    static func requireSuccess(_ json: [String: Any]) throws {
        let success = json["success"] as? Bool ?? true
        guard !success else { return }

        guard let error = json["error"] as? [String: Any] else {
            throw SimpilotError.commandFailed(code: "unknown", message: "Request failed")
        }

        let code = error["code"] as? String ?? "unknown"
        let message = error["message"] as? String ?? "Request failed"

        if code == "assertion_failed" {
            throw SimpilotError.assertionFailed(code: code, message: message)
        }

        throw SimpilotError.commandFailed(code: code, message: message)
    }

    /// Extract the `data` field from a successful response.
    static func data(from json: [String: Any]) -> Any? {
        json["data"]
    }
}
