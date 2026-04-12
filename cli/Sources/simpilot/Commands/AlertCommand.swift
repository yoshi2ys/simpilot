import Foundation

enum AlertCommand: SimpilotCommand {
    static let argSpec = ArgSpec(
        command: "alert",
        positionals: [.init(name: "action", required: true)],
        flags: [
            .init("--timeout", .double),
        ]
    )
    static let category: HelpCommands.Category = .interaction
    static let synopsis = "alert <accept|dismiss> [--timeout <s>]"
    static let description = "Accept or dismiss a system permission alert"
    static let example = "simpilot alert accept --timeout 5"

    static func run(context: RunContext) throws {
        let parsed = try ArgParser.parse(context.args, spec: argSpec)
        let action = parsed.positionals[0].lowercased()

        guard action == "accept" || action == "dismiss" else {
            throw CLIError.invalidArgs("Invalid alert action: \(action). Use 'accept' or 'dismiss'.")
        }

        var body: [String: Any] = ["action": action]
        if let timeout = parsed.double("--timeout") {
            body["timeout"] = timeout
        }

        let data = try context.client.post("/alert", body: body)
        try decodeAndPrint(data: data, pretty: context.pretty)
    }
}
