import Foundation

/// Per-agent shared secret handed to the XCUITest runner at launch.
///
/// The agent refuses to bind anything but loopback without one, so every
/// network-reachable agent is authenticated by construction.
enum TokenGenerator {
    /// 256 bits, hex-encoded. Long enough that guessing is hopeless, and ASCII
    /// so it survives the `TEST_RUNNER_*` environment round-trip unchanged.
    static func make(byteCount: Int = 32) -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<byteCount)
            .map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }
            .joined()
    }
}
