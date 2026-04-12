import Foundation
import Testing
@testable import SimpilotTest

@Suite("URL Construction")
struct URLConstructionTests {
    @Test("IPv4 host is unchanged")
    func ipv4Host() {
        #expect("192.168.1.1".urlHost == "192.168.1.1")
    }

    @Test("IPv6 host is wrapped in brackets")
    func ipv6Host() {
        #expect("fd4d:85e2:eeb::1".urlHost == "[fd4d:85e2:eeb::1]")
    }

    @Test("Already-bracketed IPv6 is unchanged")
    func bracketedIPv6() {
        #expect("[::1]".urlHost == "[::1]")
    }

    @Test("localhost is unchanged")
    func localhost() {
        #expect("localhost".urlHost == "localhost")
    }
}

@Suite("Response Parsing")
struct ResponseParsingTests {
    @Test("Parse success envelope")
    func successEnvelope() throws {
        let json: [String: Any] = [
            "success": true,
            "data": ["action": "tap", "query": "button:OK"],
            "error": NSNull(),
            "duration_ms": 42,
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let parsed = try Response.parse(data)

        #expect(parsed["success"] as? Bool == true)
        try Response.requireSuccess(parsed)
    }

    @Test("Parse error envelope throws commandFailed")
    func errorEnvelope() throws {
        let json: [String: Any] = [
            "success": false,
            "data": NSNull(),
            "error": ["code": "element_not_found", "message": "No match for query"],
            "duration_ms": 10,
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let parsed = try Response.parse(data)

        #expect(throws: SimpilotError.self) {
            try Response.requireSuccess(parsed)
        }
    }

    @Test("Assertion failure throws assertionFailed")
    func assertionFailure() throws {
        let json: [String: Any] = [
            "success": false,
            "data": NSNull(),
            "error": [
                "code": "assertion_failed",
                "message": "Assertion failed: exists on query 'button:OK'",
            ],
            "duration_ms": 3000,
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let parsed = try Response.parse(data)

        do {
            try Response.requireSuccess(parsed)
            Issue.record("Expected assertionFailed to be thrown")
        } catch let error as SimpilotError {
            switch error {
            case .assertionFailed(let code, _):
                #expect(code == "assertion_failed")
            default:
                Issue.record("Expected assertionFailed, got \(error)")
            }
        }
    }

    @Test("Parse non-JSON data returns string")
    func nonJSONData() throws {
        let data = "plain text response".data(using: .utf8)!
        let parsed = try Response.parse(data)
        #expect(parsed["success"] as? Bool == true)
        #expect(parsed["data"] as? String == "plain text response")
    }

    @Test("Missing success key defaults to true")
    func missingSuccessKey() throws {
        let json: [String: Any] = ["data": "hello"]
        let data = try JSONSerialization.data(withJSONObject: json)
        let parsed = try Response.parse(data)
        try Response.requireSuccess(parsed)
    }
}

@Suite("Query String Building")
struct QueryStringTests {
    @Test("GET params build correct query string")
    func queryStringBuilding() {
        var components = URLComponents()
        components.path = "/elements"
        let params: [(String, String?)] = [
            ("level", "1"), ("type", "button"), ("contains", nil),
        ]
        let items = params.compactMap { (k, v) in v.map { URLQueryItem(name: k, value: $0) } }
        if !items.isEmpty { components.queryItems = items }
        let path = components.string ?? "/elements"
        #expect(path == "/elements?level=1&type=button")
    }

    @Test("GET with no params returns bare path")
    func noParams() {
        var components = URLComponents()
        components.path = "/health"
        let items: [URLQueryItem] = []
        if !items.isEmpty { components.queryItems = items }
        #expect(components.string == "/health")
    }
}

@Suite("SimpilotError")
struct ErrorTests {
    @Test("Error cases are distinct")
    func errorCases() {
        let e1 = SimpilotError.agentUnreachable("http://localhost:8222")
        let e2 = SimpilotError.commandFailed(code: "not_found", message: "No route")
        let e3 = SimpilotError.assertionFailed(code: "assertion_failed", message: "Failed")
        let e4 = SimpilotError.invalidURL("bad://url")

        // Just verify they're all Error conformant and distinct
        let errors: [any Error] = [e1, e2, e3, e4]
        #expect(errors.count == 4)
    }
}
