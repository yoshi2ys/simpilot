import Foundation

enum DoubleTapCommand: SimpilotCommand {
    static let argSpec = ArgSpec(
        command: "doubletap",
        positionals: [.init(name: "query", required: true)],
        flags: WaitFlags.flags
    )
    static let category: HelpCommands.Category = .interaction
    static let synopsis = "doubletap <query> \(WaitFlags.synopsis)"
    static let description = "Double-tap an element by label/query"
    static let example = "simpilot doubletap 'Edit'"

    static func run(context: RunContext) throws {
        let parsed = try ArgParser.parse(context.args, spec: argSpec)
        let query = parsed.positionals[0]

        var body: [String: Any] = ["query": query]
        WaitFlags.apply(parsed, to: &body)

        let data = try context.client.post("/doubletap", body: body)
        try decodeAndPrint(data: data, pretty: context.pretty)
    }
}
