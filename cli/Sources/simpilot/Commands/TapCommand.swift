import Foundation

enum TapCommand {
    static func run(client: HTTPClient, args: [String], pretty: Bool) throws {
        var query: String?
        var waitUntil: [String] = []
        var timeoutSeconds: Double?
        var pollIntervalMs: Int?
        var i = 0

        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--wait-until":
                i += 1
                guard i < args.count else {
                    throw CLIError.invalidArgs("Usage: simpilot tap <query> [--wait-until <csv>] [--timeout <s>] [--poll-interval <ms>]")
                }
                waitUntil = args[i]
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            case "--timeout":
                i += 1
                guard i < args.count, let t = Double(args[i]) else {
                    throw CLIError.invalidArgs("Usage: --timeout <seconds>")
                }
                timeoutSeconds = t
            case "--poll-interval":
                i += 1
                guard i < args.count, let p = Int(args[i]) else {
                    throw CLIError.invalidArgs("Usage: --poll-interval <ms>")
                }
                pollIntervalMs = p
            default:
                if query == nil {
                    query = arg
                }
            }
            i += 1
        }

        guard let query else {
            throw CLIError.invalidArgs("Usage: simpilot tap <query> [--wait-until <csv>] [--timeout <s>] [--poll-interval <ms>]")
        }

        var body: [String: Any] = ["query": query]
        if let timeoutSeconds {
            body["timeout_ms"] = Int(timeoutSeconds * 1000)
        }
        if !waitUntil.isEmpty {
            body["wait_until"] = waitUntil
        }
        if let pollIntervalMs {
            body["poll_interval_ms"] = pollIntervalMs
        }

        let data = try client.post("/tap", body: body)
        try decodeAndPrint(data: data, pretty: pretty)
    }
}
