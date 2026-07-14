import Foundation

/// Startup configuration for the agent's HTTP server, resolved from the test
/// runner's environment.
///
/// `xcodebuild test` forwards every `TEST_RUNNER_<NAME>` variable in its own
/// environment to the XCUITest runner process as `<NAME>`, on simulators and on
/// physical devices alike. That is how the CLI hands the agent its port, its
/// bind mode, and the shared token — no file on disk, no predictable path.
///
/// The invariant this type exists to enforce: **an agent reachable from the
/// network always requires a token.** `resolve` refuses to produce a config
/// that binds every interface without one, so there is no code path that can
/// serve an unauthenticated LAN listener.
struct AgentConfig: Equatable {
    /// Which interfaces the listener accepts connections on.
    enum BindMode: String {
        /// Bind `127.0.0.1` only. The simulator shares the host's network
        /// stack, so a loopback-bound agent is unreachable from the LAN.
        case loopback
        /// Bind every interface. Required for physical devices, where the CLI
        /// reaches the agent over USB/Wi-Fi via `<name>.coredevice.local`.
        /// Only legal together with a token.
        case all
    }

    static let defaultPort: UInt16 = 8222

    let port: UInt16
    let bind: BindMode
    /// Shared secret required in the `X-Simpilot-Token` request header. Nil is
    /// permitted only for a loopback-bound agent — e.g. one launched straight
    /// from Xcode for debugging.
    let token: String?

    /// Private so the synthesized memberwise init cannot hand the rest of the
    /// target an `AgentConfig(bind: .all, token: nil)` that skips `resolve`'s
    /// check. Every config is born from `resolve`.
    private init(port: UInt16, bind: BindMode, token: String?) {
        self.port = port
        self.bind = bind
        self.token = token
    }

    enum ConfigError: Error, CustomStringConvertible {
        case invalidPort(String)
        case invalidBind(String)
        case unauthenticatedPublicBind

        var description: String {
            switch self {
            case .invalidPort(let raw):
                return "SIMPILOT_PORT '\(raw)' is not a valid TCP port (1-65535)"
            case .invalidBind(let raw):
                return "SIMPILOT_BIND '\(raw)' is not valid (expected 'loopback' or 'all')"
            case .unauthenticatedPublicBind:
                return "SIMPILOT_BIND=all requires SIMPILOT_TOKEN — refusing to serve "
                    + "an unauthenticated listener on every interface"
            }
        }
    }

    static func resolve(env: [String: String]) throws -> AgentConfig {
        let port: UInt16
        if let raw = trimmed(env["SIMPILOT_PORT"]) {
            guard let parsed = UInt16(raw), parsed > 0 else {
                throw ConfigError.invalidPort(raw)
            }
            port = parsed
        } else {
            port = defaultPort
        }

        let bind: BindMode
        if let raw = trimmed(env["SIMPILOT_BIND"]) {
            guard let parsed = BindMode(rawValue: raw) else {
                throw ConfigError.invalidBind(raw)
            }
            bind = parsed
        } else {
            bind = .loopback
        }

        let token = trimmed(env["SIMPILOT_TOKEN"])

        guard bind == .loopback || token != nil else {
            throw ConfigError.unauthenticatedPublicBind
        }
        return AgentConfig(port: port, bind: bind, token: token)
    }

    /// Nil for absent, empty, or whitespace-only values so an env var set to
    /// "" never reads as a configured value.
    private static func trimmed(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

/// Shared-token authentication for every routed request.
enum TokenAuth {
    static let headerName = "X-Simpilot-Token"

    /// Compare in time independent of *where* the first mismatching byte sits,
    /// so a caller cannot brute-force the token one character at a time. The
    /// length is not secret (it is fixed by `TokenGenerator`), so an early
    /// return on a length mismatch is fine.
    static func matches(expected: String, provided: String?) -> Bool {
        guard let provided else { return false }
        let expectedBytes = Array(expected.utf8)
        let providedBytes = Array(provided.utf8)
        guard expectedBytes.count == providedBytes.count else { return false }

        var difference: UInt8 = 0
        for (lhs, rhs) in zip(expectedBytes, providedBytes) {
            difference |= lhs ^ rhs
        }
        return difference == 0
    }
}
