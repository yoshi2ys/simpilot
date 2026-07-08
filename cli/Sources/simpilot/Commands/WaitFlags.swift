import Foundation

/// Maps the common `--wait-until` / `--timeout` / `--poll-interval` flags
/// onto the wire-level `wait_until` / `timeout_ms` / `poll_interval_ms`
/// fields. Shared by every command that routes through `TapHandler`'s
/// resolve-and-wait path (tap, action, longpress, doubletap).
enum WaitFlags {
    static let flags: [ArgSpec.Flag] = [
        .init("--wait-until", .string),
        .init("--timeout", .double),
        .init("--poll-interval", .int),
    ]

    static let synopsis = "[--wait-until <csv>] [--timeout <s>] [--poll-interval <ms>]"

    /// The server-side wait budget (seconds) these flags imply, if any. The
    /// `--timeout` value bounds how long the agent's poll loop may run, so the
    /// HTTP client must wait at least this long plus a buffer — see A5.
    static func operationBudget(_ parsed: ParsedArgs) -> TimeInterval? {
        parsed.double("--timeout")
    }

    static func apply(_ parsed: ParsedArgs, to body: inout [String: Any]) {
        if let timeout = parsed.double("--timeout") {
            body["timeout_ms"] = Int(timeout * 1000)
        }
        if let waitRaw = parsed.string("--wait-until") {
            let waitUntil = waitRaw
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !waitUntil.isEmpty {
                body["wait_until"] = waitUntil
            }
        }
        if let poll = parsed.int("--poll-interval") {
            body["poll_interval_ms"] = poll
        }
    }
}
