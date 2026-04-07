import Foundation

enum ActionCommand {
    static func run(client: HTTPClient, args: [String], pretty: Bool) throws {
        guard args.count >= 2 else {
            throw CLIError.invalidArgs("Usage: simpilot action <tap|type|swipe|tapcoord> <query> [--screenshot <path>] [--level <n>] [--settle <secs>]")
        }

        let action = args[0]
        let query = args[1]

        var body: [String: Any] = ["action": action, "query": query]

        var i = 2
        while i < args.count {
            switch args[i] {
            case "--screenshot":
                i += 1
                guard i < args.count else { throw CLIError.invalidArgs("Missing value for --screenshot") }
                body["screenshot"] = args[i]
            case "--level":
                i += 1
                guard i < args.count, let level = Int(args[i]) else { throw CLIError.invalidArgs("Missing value for --level") }
                body["elements_level"] = level
            case "--settle":
                i += 1
                guard i < args.count, let settle = Double(args[i]) else { throw CLIError.invalidArgs("Missing value for --settle") }
                body["settle_timeout"] = settle
            case "--text":
                i += 1
                guard i < args.count else { throw CLIError.invalidArgs("Missing value for --text") }
                body["text"] = args[i]
            case "--direction":
                i += 1
                guard i < args.count else { throw CLIError.invalidArgs("Missing value for --direction") }
                body["direction"] = args[i]
            case "--x":
                i += 1
                guard i < args.count, let x = Double(args[i]) else { throw CLIError.invalidArgs("Missing value for --x") }
                body["x"] = x
            case "--y":
                i += 1
                guard i < args.count, let y = Double(args[i]) else { throw CLIError.invalidArgs("Missing value for --y") }
                body["y"] = y
            case "--method":
                i += 1
                guard i < args.count else { throw CLIError.invalidArgs("Missing value for --method") }
                body["method"] = args[i]
            default:
                break
            }
            i += 1
        }

        let data = try client.post("/action", body: body)
        printResponse(data: data, pretty: pretty)
    }
}
