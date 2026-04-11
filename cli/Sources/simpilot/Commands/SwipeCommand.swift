import Foundation

enum SwipeCommand {
    static func run(client: HTTPClient, args: [String], pretty: Bool) throws {
        guard !args.isEmpty else {
            throw CLIError.invalidArgs("Usage: simpilot swipe <direction> [--on <query>] [--velocity slow|default|fast]")
        }

        var direction: String?
        var query: String?
        var velocity: String?
        var i = 0

        while i < args.count {
            switch args[i] {
            case "--on":
                i += 1
                guard i < args.count else {
                    throw CLIError.invalidArgs("Usage: simpilot swipe <direction> [--on <query>] [--velocity slow|default|fast]")
                }
                query = args[i]
            case "--velocity":
                i += 1
                guard i < args.count else {
                    throw CLIError.invalidArgs("Usage: simpilot swipe <direction> [--on <query>] [--velocity slow|default|fast]")
                }
                velocity = args[i]
            default:
                if direction == nil {
                    direction = args[i]
                }
            }
            i += 1
        }

        guard let direction else {
            throw CLIError.invalidArgs("Usage: simpilot swipe <direction> [--on <query>] [--velocity slow|default|fast]")
        }

        var body: [String: Any] = ["direction": direction]
        if let query {
            body["query"] = query
        }
        if let velocity {
            body["velocity"] = velocity
        }
        let data = try client.post("/swipe", body: body)
        try decodeAndPrint(data: data, pretty: pretty)
    }
}
