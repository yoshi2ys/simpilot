import Foundation

enum TapCommand: SimpilotCommand {
    static let argSpec = ArgSpec(
        command: "tap",
        positionals: [.init(name: "query", required: true)],
        flags: WaitFlags.flags
    )
    static let category: HelpCommands.Category = .interaction
    static let synopsis = "tap <query> \(WaitFlags.synopsis)"
    static let description = "Tap an element by label/query"
    static let example = "simpilot tap 'General'"

    static func run(context: RunContext) throws {
        let parsed = try ArgParser.parse(context.args, spec: argSpec)
        let query = parsed.positionals[0]

        var body: [String: Any] = ["query": query]
        WaitFlags.apply(parsed, to: &body)

        let data = try context.client.post("/tap", body: body)
        try decodeAndPrint(data: data, pretty: context.pretty)
    }
}
