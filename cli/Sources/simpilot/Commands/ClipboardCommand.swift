import Foundation

enum ClipboardCommand: SimpilotCommand {
    static let argSpec = ArgSpec(
        command: "clipboard",
        positionals: [
            .init(name: "subcommand", required: true),
            .init(name: "text", required: false),
        ]
    )
    static let category: HelpCommands.Category = .utility
    static let synopsis = "clipboard get | clipboard set <text>"
    static let description = "Read or write the device clipboard"
    static let example = "simpilot clipboard set 'hello'"

    static func run(context: RunContext) throws {
        let parsed = try ArgParser.parse(context.args, spec: argSpec)
        let subcommand = parsed.positionals[0]

        switch subcommand {
        case "get":
            if parsed.positionals.count > 1 {
                throw CLIError.invalidArgs("clipboard get takes no arguments")
            }
            let data = try context.client.get("/clipboard")
            try decodeAndPrint(data: data, pretty: context.pretty)

        case "set":
            guard parsed.positionals.count >= 2 else {
                throw CLIError.invalidArgs("Usage: simpilot clipboard set <text>")
            }
            let text = parsed.positionals[1]
            let data = try context.client.post("/clipboard", body: ["text": text])
            try decodeAndPrint(data: data, pretty: context.pretty)

        default:
            throw CLIError.invalidArgs("Unknown subcommand '\(subcommand)'. Use 'get' or 'set'.")
        }
    }
}
