import Foundation

/// What to do next about an error, as a field of its own.
///
/// `message` says what went wrong, `hint` says how to repair it. Keeping them
/// apart is for simpilot's first consumer: an agent reading `error.hint` gets the
/// next action without parsing advice out of prose, and the same code cannot
/// advise two different repairs from two handlers.
///
/// Keyed by **code, not call site**. The repair for `element_not_found` is the
/// same wherever it is raised, and eleven sites raise it; a table keyed by code
/// cannot drift the way eleven hand-written strings would. A site with something
/// more specific to say passes `hint:` and wins — `scroll-to` does, because the
/// standard advice for `element_not_found` is "try `scroll-to`", which is absurd
/// coming from `scroll-to` itself.
///
/// Codes are absent on purpose where the repair is not uniform. `invalid_request`
/// is the largest of those: each of its ~50 sites already names the field it
/// rejected, and a generic "check the arguments" would be a line the caller
/// re-reads on every validation error without ever learning anything from it.
enum ErrorHint {

    /// The standard hint for `code`, or nil when the code has no uniform repair.
    static func standard(for code: String) -> String? { table[code] }

    /// Exposed so a test can walk every entry; `standard(for:)` is the reader.
    static let table: [String: String] = [
        "element_not_found":
            "Run `elements --format outline` to see what is on screen, then retry with a label, "
            + "`#identifier`, or — for `tap` / `type` — an `@eN` from that list. "
            + "If the element may be off screen, `scroll-to` it first.",
        "invalid_query":
            "A query is a bare label, `type:label`, `#identifier`, or `@eN`. "
            + "`elements --format outline` shows the types and labels currently on screen.",
        "no_snapshot":
            "Run `elements --format outline` first.",
        "stale_alias":
            "Run `elements --format outline` again and use an alias from the fresh list.",
        "alias_unsupported":
            "Pass the element's label or `#identifier` to this command instead of an `@eN` alias.",
        "row_unsupported":
            "Pass the element's label or `#identifier` to this command instead of an `@rN` row selector. "
            + "`elements --format outline` shows what each row is called.",
        "list_not_found":
            "A row selector needs a repeating list. The `# list @lN` lines at the top of "
            + "`elements --format outline` name every list on screen; if there is none, address the "
            + "element by label, `#identifier`, or `@eN`.",
        "ambiguous_list":
            "Name the list as well as the row — `@l1r3` is row 3 of the first list. The `# list @lN` "
            + "lines in `elements --format outline` show how many rows each one has.",
        "row_not_found":
            "Rows are numbered top to bottom over the rows currently on screen, so a row further down "
            + "has to be scrolled into view first: `swipe` the list, then re-read "
            + "`elements --format outline`.",
        "activate_failed": appNotInstalled,
        "launch_failed": appNotInstalled,
        "unsupported_platform":
            "Retrying will not help — reach the same state another way.",
        "element_still_exists":
            "The element is still on screen. Raise `--timeout`, or check with "
            + "`elements --format outline` that the step meant to dismiss it actually ran.",
        "wait_timeout":
            "Raise `--timeout`, or read the screen with `elements --format outline` — the element "
            + "may never appear.",
        "assertion_failed":
            "Re-read the screen with `elements --format outline` before asserting again.",
        "alert_not_found":
            "No system alert is on screen. Confirm with `screenshot` before dismissing one.",
        "objc_exception": gestureRaised,
        "tap_failed": gestureRaised,
        "swipe_failed": gestureRaised,
        "drag_failed": gestureRaised,
        "pinch_failed": gestureRaised,
        "slider_failed": gestureRaised,
        "screenshot_failed": gestureRaised,
        "unauthorized":
            "Send the agent's token in the `X-Simpilot-Token` header. The CLI reads it from "
            + "~/.simpilot/agents.json; `simpilot list` shows the running agents.",
        "not_found":
            "No such endpoint on this agent. The CLI and the running agent are probably different "
            + "builds — `simpilot stop --all`, rebuild the agent, then `simpilot start`.",
        "batch_failed":
            "Read `data.results`: each sub-command keeps its own error code and hint.",
        "invalid_command":
            "Every batch entry needs a `method`, a `path`, and (if present) an object `params` of "
            + "scalars. `/batch` cannot contain another `/batch`.",
        "invalid_args":
            "Run `simpilot help <command>` for the values it accepts.",
        "invalid_regex":
            "The pattern must be a valid NSRegularExpression. Use the `contains:` matcher for a "
            + "plain substring.",
        "paste_failed":
            "Send the text with `--method type` instead.",
    ]

    /// Two codes, one condition: `activate` and `launch` fail the same way and are
    /// repaired the same way, so they must not drift into two wordings.
    ///
    /// The check is named as simulator-only because it is: an agent on a physical
    /// device that runs `simctl listapps` learns nothing and has spent a round-trip.
    private static let appNotInstalled =
        "Check the bundle ID, and that the app is installed on the target device. "
        + "On a simulator, `xcrun simctl listapps <udid>` lists what is installed."

    /// The whole `*_failed` family plus `objc_exception`: XCUITest raised while
    /// acting on an element. Shared so the field does not read as intermittent —
    /// an agent that finds a hint on two of three sibling failures stops trusting it.
    private static let gestureRaised =
        "The element may have gone away mid-gesture. Re-read the screen and retry once."

    /// Codes that carry no hint **by decision**, not by omission. The repair is
    /// only in the message: `invalid_request`'s ~50 sites each name the field they
    /// rejected, and the rest report a failure whose next step depends entirely on
    /// what the message says. `ErrorHintTests` scans the agent's sources and
    /// requires every code raised anywhere to appear in this set or in `table`, so
    /// a new code cannot slip through undecided.
    static let deliberatelyWithoutHint: Set<String> = [
        "invalid_request", "invalid_direction", "bad_request", "parse_error",
        "payload_too_large", "headers_too_large", "internal_error",
        "no_element_to_tap", "alert_no_buttons", "button_failed", "write_failed",
        "skipped",
    ]
}

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
        hint: String? = nil,
        extra: [String: Any] = [:],
        data: Any = NSNull()
    ) -> Data {
        var errorObject = self.errorObject(code: code, message: message, hint: hint)
        // Merge caller-supplied fields into the error object. Callers must not set
        // "code", "message" or "hint" via extra — those are owned by the named args.
        for (key, value) in extra where key != "code" && key != "message" && key != "hint" {
            errorObject[key] = value
        }
        return envelope(success: false, data: data, error: errorObject, status: status, durationMs: durationMs)
    }

    /// The `{code, message, hint?}` object every failure carries — whether it is
    /// the envelope's own error or a sub-result nested inside a successful one
    /// (`/batch` results, `action`'s screenshot leg). One builder, so a caller
    /// never has to ask which errors have a hint and which do not.
    ///
    /// `hint` given here wins; otherwise the code's standard hint fills in.
    static func errorObject(code: String, message: String, hint: String? = nil) -> [String: Any] {
        var object: [String: Any] = [
            "code": code,
            "message": message
        ]
        if let hint = hint ?? ErrorHint.standard(for: code) {
            object["hint"] = hint
        }
        return object
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
