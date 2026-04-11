import Foundation

enum SwipeCommand: SimpilotCommand {
    static let argSpec = ArgSpec(
        command: "swipe",
        positionals: [.init(name: "direction", required: true)],
        flags: [
            .init("--on", .string),
            .init("--velocity", .string),
        ]
    )
    static let category: HelpCommands.Category = .interaction
    static let synopsis = "swipe <up|down|left|right> [--on <query>] [--velocity slow|default|fast]"
    static let description = "Swipe in a direction"
    static let example = "simpilot swipe up"

    static func run(context: RunContext) throws {
        let parsed = try ArgParser.parse(context.args, spec: argSpec)
        let direction = parsed.positionals[0]

        var body: [String: Any] = ["direction": direction]
        if let query = parsed.string("--on") {
            body["query"] = query
        }
        if let velocity = parsed.string("--velocity") {
            body["velocity"] = velocity
        }
        let data = try context.client.post("/swipe", body: body)
        try decodeAndPrint(data: data, pretty: context.pretty)
    }
}
