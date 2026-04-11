import Foundation

enum ClipboardCommand {
    static let argSpec = ArgSpec(
        command: "clipboard",
        positionals: [
            .init(name: "subcommand", required: true),
            .init(name: "text", required: false),
        ]
    )

    static func run(client: HTTPClient, args: [String], pretty: Bool) throws {
        let parsed = try ArgParser.parse(args, spec: argSpec)
        let subcommand = parsed.positionals[0]

        switch subcommand {
        case "get":
            if parsed.positionals.count > 1 {
                throw CLIError.invalidArgs("clipboard get takes no arguments")
            }
            let data = try client.get("/clipboard")
            try decodeAndPrint(data: data, pretty: pretty)

        case "set":
            guard parsed.positionals.count >= 2 else {
                throw CLIError.invalidArgs("Usage: simpilot clipboard set <text>")
            }
            let text = parsed.positionals[1]
            let data = try client.post("/clipboard", body: ["text": text])
            try decodeAndPrint(data: data, pretty: pretty)

        default:
            throw CLIError.invalidArgs("Unknown subcommand '\(subcommand)'. Use 'get' or 'set'.")
        }
    }
}
