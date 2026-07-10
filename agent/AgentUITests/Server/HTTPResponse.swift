import Foundation

enum HTTPResponseBuilder {
    static func json(_ data: Any, status: Int = 200, durationMs: Double = 0) -> Data {
        envelope(success: true, data: data, error: NSNull(), status: status, durationMs: durationMs)
    }

    /// A failure envelope. `data` is `null` for the usual case, where a failed
    /// request has nothing to report but the failure. `/batch` overrides it: the
    /// caller must still see every sub-command's result, since one who cannot
    /// tell *which* command failed is no better off than one who saw nothing.
    static func error(
        _ message: String,
        code: String,
        status: Int = 400,
        durationMs: Double = 0,
        extra: [String: Any] = [:],
        data: Any = NSNull()
    ) -> Data {
        var errorObject: [String: Any] = [
            "code": code,
            "message": message
        ]
        // Merge caller-supplied fields into the error object. Callers must not
        // set "code" or "message" via extra — those are owned by the first two args.
        for (key, value) in extra where key != "code" && key != "message" {
            errorObject[key] = value
        }
        return envelope(success: false, data: data, error: errorObject, status: status, durationMs: durationMs)
    }

    /// The one place the envelope's shape is written. `classify` on the CLI side
    /// depends on every response having a boolean `success`.
    private static func envelope(success: Bool, data: Any, error: Any, status: Int, durationMs: Double) -> Data {
        buildHTTP(
            jsonObject: [
                "success": success,
                "data": data,
                "error": error,
                "duration_ms": Int(durationMs)
            ],
            status: status
        )
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
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 408: return "Request Timeout"
        case 413: return "Payload Too Large"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        default: return "Unknown"
        }
    }
}
