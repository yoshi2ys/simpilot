import Foundation

enum HTTPResponseBuilder {
    static func json(_ data: Any, status: Int = 200, durationMs: Double = 0) -> Data {
        let envelope: [String: Any] = [
            "success": true,
            "data": data,
            "error": NSNull(),
            "duration_ms": Int(durationMs)
        ]
        return buildHTTP(jsonObject: envelope, status: status)
    }

    static func error(_ message: String, code: String, status: Int = 400, durationMs: Double = 0) -> Data {
        let envelope: [String: Any] = [
            "success": false,
            "data": NSNull(),
            "error": [
                "code": code,
                "message": message
            ],
            "duration_ms": Int(durationMs)
        ]
        return buildHTTP(jsonObject: envelope, status: status)
    }

    private static func buildHTTP(jsonObject: [String: Any], status: Int) -> Data {
        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys])
        } catch {
            body = "{\"success\":false,\"error\":{\"code\":\"serialization_error\",\"message\":\"Failed to serialize response\"},\"data\":null,\"duration_ms\":0}".data(using: .utf8) ?? Data()
        }

        let statusText = httpStatusText(status)
        var response = "HTTP/1.1 \(status) \(statusText)\r\n"
        response += "Content-Type: application/json; charset=utf-8\r\n"
        response += "Content-Length: \(body.count)\r\n"
        response += "Connection: close\r\n"
        response += "\r\n"

        var responseData = response.data(using: .utf8) ?? Data()
        responseData.append(body)
        return responseData
    }

    private static func httpStatusText(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default: return "Unknown"
        }
    }
}
