import Foundation

enum ScrollToCommand: SimpilotCommand {
    static let argSpec = ArgSpec(
        command: "scroll-to",
        positionals: [.init(name: "query", required: true)],
        flags: [
            .init("--direction", .string),
            .init("--max-swipes", .int),
            .init("--settle", .double),
        ]
    )
    static let category: HelpCommands.Category = .interaction
    static let synopsis = "scroll-to <query> [--direction <up|down|left|right>] [--max-swipes <N>] [--settle <s>]"
    static let description = "Scroll to find an element"
    static let example = "simpilot scroll-to 'Privacy' --direction down --max-swipes 15"

    static func run(context: RunContext) throws {
        let parsed = try ArgParser.parse(context.args, spec: argSpec)
        let query = parsed.positionals[0]

        var body: [String: Any] = ["query": query]
        if let direction = parsed.string("--direction") {
            body["direction"] = direction
        }
        if let maxSwipes = parsed.int("--max-swipes") {
            guard maxSwipes > 0 else {
                throw CLIError.invalidArgs("scroll-to: --max-swipes must be greater than 0")
            }
            body["max_swipes"] = maxSwipes
        }
        if let settle = parsed.double("--settle") {
            body["settle"] = settle
        }
        let data = try context.client.post("/scroll-to", body: body)
        try decodeAndPrint(data: data, pretty: context.pretty)
    }
}
