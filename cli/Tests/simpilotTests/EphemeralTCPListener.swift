import Foundation

/// A TCP listener on a kernel-chosen port of `127.0.0.1`.
///
/// The bind/listen/getsockname bootstrap is identical for every test server we
/// need; only what each does after `accept` differs (`StallingServer` never
/// replies, `StubAgent` answers with a canned envelope). Keeping the socket
/// setup in one place is what stops the two from drifting.
struct EphemeralTCPListener {
    let fd: Int32
    let port: UInt16

    init(backlog: Int32 = 1) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Self.lastError() }

        // Each syscall reports its own errno. Collapsing them into one hardcoded
        // code would misdiagnose the next test that fails here.
        func failing() -> Error {
            let error = Self.lastError()
            close(fd)
            return error
        }

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
        guard bound == 0 else { throw failing() }
        guard listen(fd, backlog) == 0 else { throw failing() }

        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard named == 0 else { throw failing() }

        self.fd = fd
        self.port = UInt16(bigEndian: boundAddr.sin_port)
    }

    private static func lastError() -> Error {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
