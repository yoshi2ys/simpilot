import Foundation

struct HTTPRequest {
    let method: String
    let path: String
    let queryParams: [String: String]
    let headers: [String: String]
    var body: Data
}

enum HTTPParser {
    /// Upper bound on a single request body. Requests to the agent are small
    /// JSON payloads (queries, text, clipboard); anything larger is rejected
    /// (413) rather than buffered, capping per-connection memory.
    static let maxBodySize = 16 * 1024 * 1024   // 16 MB
    /// Upper bound on the header block before the terminating CRLFCRLF. Stops a
    /// slow client from making us buffer unbounded header bytes (slowloris).
    static let maxHeaderSize = 64 * 1024        // 64 KB
    /// Total bytes tolerated per connection (headers + body). `classify` owns
    /// this ceiling so a client can't split an oversized payload across the two
    /// per-field caps to slip past either one alone.
    static let maxRequestSize = maxHeaderSize + maxBodySize

    /// Classification of an accumulating request buffer for the server's
    /// receive loop: keep reading, dispatch, or reject with a status.
    enum ParseResult {
        case needMoreData
        case complete(HTTPRequest)
        case reject(status: Int, code: String, message: String)
    }

    /// Validity of a declared Content-Length header.
    enum ContentLength: Equatable {
        case absent
        case value(Int)
        case invalid
    }

    /// Incremental parse state threaded across `connection.receive` chunks so
    /// the header block is located and parsed exactly once — later chunks only
    /// wait for the body to finish arriving (A3: no O(n²) re-parse while a body
    /// streams in). One instance per connection.
    final class RequestAccumulator {
        fileprivate var headerEnd: Int?
        fileprivate var head: HTTPRequest?
        fileprivate var contentLength = 0
    }

    /// Find the byte offset where headers end (after \r\n\r\n). Returns the
    /// index of the first body byte, or nil if the terminator isn't present.
    static func findHeaderEnd(_ data: Data) -> Int? {
        guard let range = data.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) else { return nil }
        return data.distance(from: data.startIndex, to: range.upperBound)
    }

    /// Case-insensitive header lookup. HTTP header names are case-insensitive,
    /// so `Content-Length` and `content-length` must resolve the same value.
    static func headerValue(_ name: String, in headers: [String: String]) -> String? {
        if let exact = headers[name] { return exact }
        let lower = name.lowercased()
        for (key, value) in headers where key.lowercased() == lower {
            return value
        }
        return nil
    }

    /// Declared body length, guarding against non-numeric, overflowing, or
    /// negative values. A garbage `Content-Length` is reported as `.invalid`
    /// (400) rather than silently coerced to 0 — see A20 "no silent failure".
    static func declaredContentLength(_ headers: [String: String]) -> ContentLength {
        guard let raw = headerValue("Content-Length", in: headers) else {
            return .absent
        }
        // Int(_:) fails on overflow (> Int.max) and on non-numeric text.
        guard let length = Int(raw.trimmingCharacters(in: .whitespaces)), length >= 0 else {
            return .invalid
        }
        return .value(length)
    }

    /// Stateless convenience over `classify(_:into:)` for one-shot callers and
    /// tests. Equivalent to feeding the whole buffer in a single chunk.
    static func classify(_ data: Data) -> ParseResult {
        classify(data, into: RequestAccumulator())
    }

    /// The single owner of every request-size limit (A1 overflow safety + A3
    /// memory bounds). Bounds total, header, and body size, never performs an
    /// unchecked index addition against an attacker-controlled Content-Length,
    /// and caches the parsed head in `acc` so a streaming body is not re-parsed
    /// on every chunk. Pass the same `acc` back for each chunk of a connection.
    static func classify(_ data: Data, into acc: RequestAccumulator) -> ParseResult {
        // Total ceiling first, so an endless header stream or a lying
        // Content-Length can't exhaust memory before the per-field checks.
        if data.count > maxRequestSize {
            return .reject(
                status: 413,
                code: "payload_too_large",
                message: "Request exceeds \(maxRequestSize) bytes"
            )
        }

        // Phase 1: locate and parse the header block exactly once.
        if acc.head == nil {
            guard let headerEnd = findHeaderEnd(data) else {
                if data.count > maxHeaderSize {
                    return .reject(
                        status: 431,
                        code: "headers_too_large",
                        message: "Request headers exceed \(maxHeaderSize) bytes"
                    )
                }
                return .needMoreData
            }
            // Terminated but oversized header block (the no-terminator branch
            // above can't catch this once the CRLFCRLF has arrived).
            if headerEnd > maxHeaderSize {
                return .reject(
                    status: 431,
                    code: "headers_too_large",
                    message: "Request headers exceed \(maxHeaderSize) bytes"
                )
            }
            guard let head = parseHead(data, headerEnd: headerEnd) else {
                return .reject(status: 400, code: "bad_request", message: "Malformed request line")
            }
            switch declaredContentLength(head.headers) {
            case .absent:
                acc.contentLength = 0
            case .invalid:
                return .reject(status: 400, code: "bad_request", message: "Invalid Content-Length header")
            case .value(let n):
                if n > maxBodySize {
                    return .reject(
                        status: 413,
                        code: "payload_too_large",
                        message: "Request body of \(n) bytes exceeds limit of \(maxBodySize)"
                    )
                }
                acc.contentLength = n
            }
            acc.headerEnd = headerEnd
            acc.head = head
        }

        // Phase 2: wait for the body — O(1) per chunk.
        guard let headerEnd = acc.headerEnd, var request = acc.head else {
            return .needMoreData
        }
        let available = data.count - headerEnd
        if available < acc.contentLength {
            return .needMoreData
        }
        request.body = sliceBody(data, headerEnd: headerEnd, length: acc.contentLength)
        return .complete(request)
    }

    /// Overflow-safe one-shot parse used by tests and any direct caller. Clamps
    /// the body to what was actually received and to `maxBodySize`, so a bogus
    /// Content-Length can never trigger an out-of-range slice or an index
    /// overflow (A1). Returns nil only when the request line/headers are absent
    /// or malformed.
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let headerEnd = findHeaderEnd(data) else { return nil }
        guard var request = parseHead(data, headerEnd: headerEnd) else { return nil }

        let declared: Int
        switch declaredContentLength(request.headers) {
        case .absent, .invalid:
            declared = 0
        case .value(let n):
            declared = min(n, maxBodySize)
        }

        // findHeaderEnd only yields offsets in 4...data.count, so the
        // subtraction is always non-negative.
        let length = min(declared, data.count - headerEnd)
        request.body = sliceBody(data, headerEnd: headerEnd, length: length)
        return request
    }

    // MARK: - Internals

    /// Extract `length` body bytes starting at `headerEnd`. Callers must have
    /// already ensured `length <= data.count - headerEnd`.
    private static func sliceBody(_ data: Data, headerEnd: Int, length: Int) -> Data {
        let bodyStart = data.startIndex.advanced(by: headerEnd)
        let bodyEnd = bodyStart.advanced(by: length)
        return Data(data[bodyStart..<bodyEnd])
    }

    /// Parse the request line, query params, and header fields. The returned
    /// request carries an empty body; the caller owns body extraction.
    private static func parseHead(_ data: Data, headerEnd: Int) -> HTTPRequest? {
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

        return HTTPRequest(
            method: method,
            path: path,
            queryParams: queryParams,
            headers: headers,
            body: Data()
        )
    }
}
