import Foundation

enum WaitCommand {
    static func run(client: HTTPClient, args: [String], pretty: Bool) throws {
        guard !args.isEmpty else {
            throw CLIError.invalidArgs("Usage: simpilot wait <query> [--timeout <s>] [--gone]")
        }

        var query: String?
        var timeout: Double?
        var gone = false
        var i = 0

        while i < args.count {
            switch args[i] {
            case "--timeout":
                i += 1
                guard i < args.count, let t = Double(args[i]) else {
                    throw CLIError.invalidArgs("Usage: simpilot wait <query> [--timeout <s>] [--gone]")
                }
                timeout = t
            case "--gone":
                gone = true
            default:
                if query == nil {
                    query = args[i]
                }
            }
            i += 1
        }

        guard let query else {
            throw CLIError.invalidArgs("Usage: simpilot wait <query> [--timeout <s>] [--gone]")
        }

        var body: [String: Any] = [
            "query": query,
            "exists": !gone
        ]
        if let timeout {
            body["timeout"] = timeout
        }

        let data = try client.post("/wait", body: body)
        try decodeAndPrint(data: data, pretty: pretty)
    }
}
