import Foundation

enum WaitCommand: SimpilotCommand {
    static let argSpec = ArgSpec(
        command: "wait",
        positionals: [.init(name: "query", required: true)],
        flags: [
            .init("--timeout", .double),
            .init("--gone", .bool),
        ]
    )
    static let category: HelpCommands.Category = .interaction
    static let synopsis = "wait <query> [--timeout <s>] [--gone]"
    static let description = "Wait for element to appear or disappear"
    static let example = "simpilot wait 'General' --timeout 10"

    static func run(context: RunContext) throws {
        let parsed = try ArgParser.parse(context.args, spec: argSpec)
        let query = parsed.positionals[0]

        var body: [String: Any] = [
            "query": query,
            "exists": !parsed.bool("--gone")
        ]
        if let timeout = parsed.double("--timeout") {
            body["timeout"] = timeout
        }

        let data = try context.client.post("/wait", body: body)
        try decodeAndPrint(data: data, pretty: context.pretty)
    }
}
