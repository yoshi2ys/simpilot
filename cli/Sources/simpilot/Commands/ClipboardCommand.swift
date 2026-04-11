import Foundation

enum ClipboardCommand {
    static func run(client: HTTPClient, args: [String], pretty: Bool) throws {
        guard let subcommand = args.first else {
            throw CLIError.invalidArgs("Usage: simpilot clipboard <get|set> [text]")
        }

        switch subcommand {
        case "get":
            let data = try client.get("/clipboard")
            try decodeAndPrint(data: data, pretty: pretty)

        case "set":
            guard args.count >= 2 else {
                throw CLIError.invalidArgs("Usage: simpilot clipboard set <text>")
            }
            let text = args[1]
            let data = try client.post("/clipboard", body: ["text": text])
            try decodeAndPrint(data: data, pretty: pretty)

        default:
            throw CLIError.invalidArgs("Unknown subcommand '\(subcommand)'. Use 'get' or 'set'.")
        }
    }
}
