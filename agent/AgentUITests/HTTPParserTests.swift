import XCTest

/// Coverage for the hardened HTTP parser (improvement-plan A1 + A3):
/// Content-Length overflow safety, request-size bounds, and the `classify`
/// state machine the server relies on to reject hostile buffers instead of
/// buffering unbounded memory or crashing on an unchecked index addition.
final class HTTPParserTests: XCTestCase {

    /// Build a raw request buffer. Content-Length is only set when the caller
    /// passes it explicitly, so tests can exercise invalid/overflowing values.
    private func requestData(
        method: String = "POST",
        path: String = "/tap",
        headers: [String: String] = [:],
        body: Data = Data()
    ) -> Data {
        var head = "\(method) \(path) HTTP/1.1\r\n"
        for (key, value) in headers {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    // MARK: - A1: Content-Length overflow safety

    func test_parse_intMaxContentLength_doesNotCrashAndClampsBody() {
        let body = Data("hi".utf8)
        let data = requestData(headers: ["Content-Length": "\(Int.max)"], body: body)
        // The old code did `bodyStart + contentLength` → Int overflow → crash.
        let request = HTTPParser.parse(data)
        XCTAssertNotNil(request)
        XCTAssertEqual(request?.body, body, "body must clamp to bytes actually received")
    }

    func test_classify_intMaxContentLength_rejects413() {
        let data = requestData(headers: ["Content-Length": "\(Int.max)"], body: Data("hi".utf8))
        guard case .reject(let status, let code, _) = HTTPParser.classify(data) else {
            return XCTFail("expected reject for Int.max Content-Length")
        }
        XCTAssertEqual(status, 413)
        XCTAssertEqual(code, "payload_too_large")
    }

    func test_parse_overflowingContentLength_treatedAsEmptyBody() {
        // Larger than Int.max → Int() fails → not silently a body length.
        let data = requestData(headers: ["Content-Length": "99999999999999999999999999"], body: Data("hi".utf8))
        XCTAssertEqual(HTTPParser.parse(data)?.body.count, 0)
    }

    func test_classify_overflowingContentLength_rejects400() {
        let data = requestData(headers: ["Content-Length": "99999999999999999999999999"], body: Data("hi".utf8))
        guard case .reject(let status, let code, _) = HTTPParser.classify(data) else {
            return XCTFail("expected reject for overflowing Content-Length")
        }
        XCTAssertEqual(status, 400)
        XCTAssertEqual(code, "bad_request")
    }

    func test_classify_negativeContentLength_rejects400() {
        let data = requestData(headers: ["Content-Length": "-5"], body: Data("hi".utf8))
        guard case .reject(let status, _, _) = HTTPParser.classify(data) else {
            return XCTFail("expected reject for negative Content-Length")
        }
        XCTAssertEqual(status, 400)
    }

    // MARK: - declaredContentLength

    func test_declaredContentLength_variants() {
        XCTAssertEqual(HTTPParser.declaredContentLength([:]), .absent)
        XCTAssertEqual(HTTPParser.declaredContentLength(["Content-Length": "10"]), .value(10))
        XCTAssertEqual(HTTPParser.declaredContentLength(["Content-Length": "0"]), .value(0))
        XCTAssertEqual(HTTPParser.declaredContentLength(["Content-Length": "-1"]), .invalid)
        XCTAssertEqual(HTTPParser.declaredContentLength(["Content-Length": "abc"]), .invalid)
        // Case-insensitive per RFC 9110 — mixed case must still resolve.
        XCTAssertEqual(HTTPParser.declaredContentLength(["cOnTeNt-LeNgTh": "5"]), .value(5))
    }

    // MARK: - A3: body size bounds

    func test_classify_bodyOverMaxSize_rejects413() {
        let data = requestData(headers: ["Content-Length": "\(HTTPParser.maxBodySize + 1)"])
        guard case .reject(let status, let code, _) = HTTPParser.classify(data) else {
            return XCTFail("expected reject for body over maxBodySize")
        }
        XCTAssertEqual(status, 413)
        XCTAssertEqual(code, "payload_too_large")
    }

    func test_classify_bodyAtMaxSize_notRejectedForSize() {
        // At the limit the size check passes; body isn't fully received yet.
        let data = requestData(headers: ["Content-Length": "\(HTTPParser.maxBodySize)"])
        if case .reject = HTTPParser.classify(data) {
            XCTFail("maxBodySize must be allowed by the size gate")
        }
    }

    // MARK: - A3: header size bound (slowloris)

    func test_classify_oversizedHeadersWithoutTerminator_rejects431() {
        var data = Data("GET /x HTTP/1.1\r\n".utf8)
        // No CRLFCRLF terminator, so headers never "end"; exceed the cap.
        data.append(Data(repeating: 0x41, count: HTTPParser.maxHeaderSize + 1))
        guard case .reject(let status, let code, _) = HTTPParser.classify(data) else {
            return XCTFail("expected reject for oversized headers")
        }
        XCTAssertEqual(status, 431)
        XCTAssertEqual(code, "headers_too_large")
    }

    func test_classify_incompleteHeadersUnderLimit_needMoreData() {
        let data = Data("GET /x HTTP/1.1\r\n".utf8) // no terminator, small
        guard case .needMoreData = HTTPParser.classify(data) else {
            return XCTFail("small incomplete header stream must keep reading")
        }
    }

    /// Closes the gap the altitude review found: the no-terminator branch can't
    /// catch an oversized header block once the CRLFCRLF has already arrived.
    func test_classify_terminatedOversizedHeaders_rejects431() {
        var data = Data("GET / HTTP/1.1\r\nX-Big: ".utf8)
        data.append(Data(repeating: 0x41, count: HTTPParser.maxHeaderSize))
        data.append(Data("\r\n\r\n".utf8)) // terminated, but header block > maxHeaderSize
        guard case .reject(let status, let code, _) = HTTPParser.classify(data) else {
            return XCTFail("terminated oversized headers must be rejected")
        }
        XCTAssertEqual(status, 431)
        XCTAssertEqual(code, "headers_too_large")
    }

    func test_classify_totalBytesOverCeiling_rejects413() {
        // No header terminator, but total bytes blow past the header+body ceiling.
        var data = Data("GET / HTTP/1.1\r\n".utf8)
        data.append(Data(repeating: 0x41, count: HTTPParser.maxRequestSize + 1))
        guard case .reject(let status, _, _) = HTTPParser.classify(data) else {
            return XCTFail("buffer over the total ceiling must be rejected")
        }
        XCTAssertEqual(status, 413)
    }

    // MARK: - A3: incremental accumulation across chunks

    /// The header block is parsed once and cached; a body that arrives in
    /// several chunks completes without re-parsing headers each time.
    func test_classify_incremental_completesAcrossChunks() {
        let body = Data("{\"query\":\"General\"}".utf8)
        let full = requestData(headers: ["Content-Length": "\(body.count)"], body: body)
        let accumulator = HTTPParser.RequestAccumulator()

        // First chunk: full headers, body short by 3 bytes.
        let chunk1 = Data(full.prefix(full.count - 3))
        guard case .needMoreData = HTTPParser.classify(chunk1, into: accumulator) else {
            return XCTFail("partial body should need more data")
        }

        // Second chunk: the rest arrives.
        guard case .complete(let request) = HTTPParser.classify(full, into: accumulator) else {
            return XCTFail("full buffer should complete")
        }
        XCTAssertEqual(request.body, body)
        XCTAssertEqual(request.path, "/tap")
    }

    // MARK: - classify: normal flow

    func test_classify_partialBody_needMoreData() {
        // Declares 10, only 2 received.
        let data = requestData(headers: ["Content-Length": "10"], body: Data("hi".utf8))
        guard case .needMoreData = HTTPParser.classify(data) else {
            return XCTFail("partial body must request more data")
        }
    }

    func test_classify_completeBody_returnsRequest() {
        let body = Data("{\"query\":\"General\"}".utf8)
        let data = requestData(headers: ["Content-Length": "\(body.count)"], body: body)
        guard case .complete(let request) = HTTPParser.classify(data) else {
            return XCTFail("full request must classify as complete")
        }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/tap")
        XCTAssertEqual(request.body, body)
    }

    func test_classify_noBodyGet_completesImmediately() {
        let data = requestData(method: "GET", path: "/health")
        guard case .complete(let request) = HTTPParser.classify(data) else {
            return XCTFail("bodyless GET must classify as complete")
        }
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/health")
        XCTAssertEqual(request.body.count, 0)
    }

    // MARK: - parse: headers & query

    func test_parse_mixedCaseContentLength_extractsBody() {
        let body = Data("abcd".utf8)
        let data = requestData(headers: ["cOnTeNt-LeNgTh": "4"], body: body)
        XCTAssertEqual(HTTPParser.parse(data)?.body, body)
    }

    func test_parse_queryPercentDecoding() {
        let data = requestData(method: "GET", path: "/elements?contains=Hello%20World&type=button")
        let request = HTTPParser.parse(data)
        XCTAssertEqual(request?.queryParams["contains"], "Hello World")
        XCTAssertEqual(request?.queryParams["type"], "button")
    }

    func test_parse_malformedRequestLine_returnsNil() {
        let data = Data("GARBAGE\r\n\r\n".utf8)
        XCTAssertNil(HTTPParser.parse(data), "single-token request line has no path")
    }

    func test_findHeaderEnd_pointsAtFirstBodyByte() {
        let data = Data("GET / HTTP/1.1\r\nHost: x\r\n\r\nBODY".utf8)
        guard let end = HTTPParser.findHeaderEnd(data) else {
            return XCTFail("terminator present")
        }
        let bodyStart = data.startIndex.advanced(by: end)
        XCTAssertEqual(String(data: data[bodyStart...], encoding: .utf8), "BODY")
    }
}
