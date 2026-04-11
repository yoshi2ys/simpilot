import Foundation

enum AssertCommand {
    static let argSpec = ArgSpec(
        command: "assert",
        positionals: [
            .init(name: "predicate", required: true),
            .init(name: "query", required: true),
            .init(name: "expected", required: false),
        ],
        flags: [
            .init("--timeout", .double),
            .init("--snapshot-on-fail", .bool),
        ]
    )

    static func run(client: HTTPClient, args: [String], pretty: Bool) throws {
        let parsed = try ArgParser.parse(args, spec: argSpec)
        let predicate = parsed.positionals[0]
        let query = parsed.positionals[1]
        let expected: String? = parsed.positionals.count >= 3 ? parsed.positionals[2] : nil

        var body: [String: Any] = [
            "predicate": predicate,
            "query": query,
            "snapshot_on_fail": parsed.bool("--snapshot-on-fail"),
        ]
        if let expected {
            // Preflight regex compile so typos surface with exit 3 locally
            // instead of making a round-trip to the agent just to learn the
            // pattern is invalid.
            if expected.hasPrefix("regex:") {
                let pattern = String(expected.dropFirst("regex:".count))
                do {
                    _ = try NSRegularExpression(pattern: pattern, options: [])
                } catch {
                    throw CLIError.invalidArgs("Invalid regex '\(pattern)': \(error.localizedDescription)")
                }
            }
            body["expected"] = expected
        }
        // Explicit 0 means "check once, no retry".
        body["timeout_ms"] = Int((parsed.double("--timeout") ?? 3.0) * 1000)

        let data = try client.post("/assert", body: body)
        try decodeAndPrint(data: data, pretty: pretty)
    }
}
