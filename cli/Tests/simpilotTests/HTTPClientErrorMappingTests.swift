import Foundation
import XCTest
@testable import simpilot

/// A6's contract: a request that times out is a *reachable* agent that outran
/// its deadline, and must not be reported (or exit) as `agent_unreachable`.
/// Both branches are exercised against real sockets — the distinction lives in
/// `URLError` codes, which a mock would have to fabricate.
final class HTTPClientErrorMappingTests: XCTestCase {

    func testConnectionRefusedMapsToAgentUnreachable() {
        // Port 1 is reserved and nothing listens on it, so connect() gets ECONNREFUSED.
        let client = HTTPClient(baseURL: "http://127.0.0.1:1", timeout: 2)
        XCTAssertThrowsError(try client.get("/health")) { error in
            guard case CLIError.agentUnreachable(let url) = error else {
                return XCTFail("expected agentUnreachable, got \(error)")
            }
            XCTAssertEqual(url, "http://127.0.0.1:1")
        }
    }

    func testHostNotFoundMapsToAgentUnreachable() {
        let client = HTTPClient(baseURL: "http://simpilot.invalid:8222", timeout: 3)
        XCTAssertThrowsError(try client.get("/health")) { error in
            guard case CLIError.agentUnreachable = error else {
                return XCTFail("expected agentUnreachable, got \(error)")
            }
        }
    }

    /// A server that completes the TCP handshake and then says nothing — the
    /// shape of an agent still working on a long `wait`.
    func testStalledServerMapsToAgentTimeoutNotUnreachable() throws {
        let server = try StallingServer()
        defer { server.stop() }

        let client = HTTPClient(baseURL: "http://127.0.0.1:\(server.port)", timeout: 1)
        XCTAssertThrowsError(try client.get("/wait")) { error in
            guard case CLIError.agentTimeout(let url, let seconds) = error else {
                return XCTFail("a reachable-but-slow agent must not read as unreachable: \(error)")
            }
            XCTAssertEqual(url, "http://127.0.0.1:\(server.port)")
            XCTAssertEqual(seconds, 1)
        }
    }

    /// Pins the real mapping (`Simpilot.envelope`), not a copy of it.
    func testTimeoutAndUnreachableGetDistinctCodesAndExits() {
        let timeout = Simpilot.envelope(for: .agentTimeout("http://x:8222", 30))
        XCTAssertEqual(timeout.code, "agent_timeout")
        XCTAssertEqual(timeout.status, 4)
        XCTAssertTrue(timeout.message.contains("30s"), timeout.message)

        let unreachable = Simpilot.envelope(for: .agentUnreachable("http://x:8222"))
        XCTAssertEqual(unreachable.code, "agent_unreachable")
        XCTAssertEqual(unreachable.status, 1)

        XCTAssertNotEqual(
            timeout.status, unreachable.status,
            "collapsing these tells a caller to give up when it should retry"
        )
    }

    func testRemainingErrorsKeepTheirDocumentedExitCodes() {
        XCTAssertEqual(Simpilot.envelope(for: .invalidArgs("bad")).status, 3)
        XCTAssertEqual(Simpilot.envelope(for: .commandFailed("boom")).status, 2)
        // An unparseable URL is a caller mistake, so it exits 3 like other bad args.
        let invalidURL = Simpilot.envelope(for: .invalidURL("http://[::1:8222"))
        XCTAssertEqual(invalidURL.code, "invalid_args")
        XCTAssertEqual(invalidURL.status, 3)
    }
}

/// Accepts one connection and never replies, so the client hits its deadline.
private final class StallingServer: @unchecked Sendable {
    let port: UInt16
    private let listenFD: Int32
    private let accepted = AcceptedSocket()
    private let queue = DispatchQueue(label: "stalling-server")

    /// The accept happens after `init` returns, so the descriptor lives in its
    /// own box rather than in a property the initializer would have to capture.
    private final class AcceptedSocket: @unchecked Sendable {
        private let lock = NSLock()
        private var fd: Int32 = -1
        func store(_ value: Int32) { lock.lock(); fd = value; lock.unlock() }
        func closeIfOpen() {
            lock.lock()
            if fd >= 0 { close(fd); fd = -1 }
            lock.unlock()
        }
    }

    init() throws {
        // A local, not the property: the pointer closures below would otherwise
        // capture `self` before `port` is initialized.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        listenFD = fd

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // let the kernel pick a free port
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }

        var bound_addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &bound_addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard named == 0 else {
            close(fd)
            throw POSIXError(.EIO)
        }
        port = UInt16(bigEndian: bound_addr.sin_port)

        let box = accepted
        queue.async {
            box.store(accept(fd, nil, nil)) // held open, deliberately unanswered
        }
    }

    func stop() {
        accepted.closeIfOpen()
        close(listenFD)
    }
}
