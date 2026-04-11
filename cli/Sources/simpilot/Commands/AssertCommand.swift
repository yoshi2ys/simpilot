import Foundation

enum AssertCommand {
    static func run(client: HTTPClient, args: [String], pretty: Bool) throws {
        guard let predicate = args.first else {
            throw CLIError.invalidArgs(usage)
        }

        let rest = Array(args.dropFirst())
        var positional: [String] = []
        var timeoutSeconds: Double?
        var snapshotOnFail = false
        var i = 0

        while i < rest.count {
            switch rest[i] {
            case "--timeout":
                i += 1
                guard i < rest.count, let t = Double(rest[i]) else {
                    throw CLIError.invalidArgs("--timeout requires a number of seconds")
                }
                timeoutSeconds = t
            case "--snapshot-on-fail":
                snapshotOnFail = true
            default:
                positional.append(rest[i])
            }
            i += 1
        }

        guard let query = positional.first else {
            throw CLIError.invalidArgs(usage)
        }

        var body: [String: Any] = [
            "predicate": predicate,
            "query": query,
            "snapshot_on_fail": snapshotOnFail
        ]
        if positional.count >= 2 {
            body["expected"] = positional[1]
        }
        // Default 3s timeout matches the plan; explicit 0 means "check once, no retry".
        body["timeout_ms"] = Int((timeoutSeconds ?? 3.0) * 1000)

        let data = try client.post("/assert", body: body)
        try decodeAndPrint(data: data, pretty: pretty)
    }

    private static let usage =
        "Usage: simpilot assert <exists|not-exists|enabled|value|label> <query> [expected] [--timeout <s>] [--snapshot-on-fail]"
}
