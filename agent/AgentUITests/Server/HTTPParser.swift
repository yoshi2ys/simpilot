import Foundation

struct HTTPRequest {
    let method: String
    let path: String
    let queryParams: [String: String]
    let headers: [String: String]
    let body: Data
}

enum HTTPParser {
    /// Find the byte offset where headers end (after \r\n\r\n). Returns the index of the first body byte.
    static func findHeaderEnd(_ data: Data) -> Int? {
        let separator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A] // \r\n\r\n
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }
        for i in 0...(bytes.count - 4) {
            if bytes[i] == separator[0] &&
               bytes[i+1] == separator[1] &&
               bytes[i+2] == separator[2] &&
               bytes[i+3] == separator[3] {
                return i + 4
            }
        }
        return nil
    }

    static func parse(_ data: Data) -> HTTPRequest? {
        guard let headerEnd = findHeaderEnd(data) else { return nil }

        let headerData = data[data.startIndex..<data.startIndex.advanced(by: headerEnd)]
        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }

        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return nil }

        let method = String(parts[0])
        let rawPath = String(parts[1])

        // Split path and query string
        let pathComponents = rawPath.split(separator: "?", maxSplits: 1)
        let path = String(pathComponents[0])
        var queryParams: [String: String] = [:]
        if pathComponents.count > 1 {
            let queryString = String(pathComponents[1])
            for pair in queryString.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                    let value = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                    queryParams[key] = value
                } else if kv.count == 1 {
                    queryParams[String(kv[0])] = ""
                }
            }
        }

        // Parse headers
        var headers: [String: String] = [:]
        for i in 1..<lines.count {
            let line = lines[i]
            if line.isEmpty { break }
            if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[line.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        // Extract body
        let contentLength = Int(headers["Content-Length"] ?? headers["content-length"] ?? "0") ?? 0
        let bodyStart = data.startIndex.advanced(by: headerEnd)
        let bodyEnd = min(bodyStart + contentLength, data.endIndex)
        let body = data[bodyStart..<bodyEnd]

        return HTTPRequest(
            method: method,
            path: path,
            queryParams: queryParams,
            headers: headers,
            body: Data(body)
        )
    }
}
