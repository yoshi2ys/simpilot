import Foundation

enum LongPressCommand: SimpilotCommand {
    static let argSpec = ArgSpec(
        command: "longpress",
        positionals: [.init(name: "query", required: true)],
        flags: [
            .init("--duration", .double),
        ] + WaitFlags.flags
    )
    static let category: HelpCommands.Category = .interaction
    static let synopsis = "longpress <query> [--duration <s>] \(WaitFlags.synopsis)"
    static let description = "Long-press an element by label/query (default 0.8s)"
    static let example = "simpilot longpress 'Safari' --duration 1.5"

    static func run(context: RunContext) throws {
        let parsed = try ArgParser.parse(context.args, spec: argSpec)
        let query = parsed.positionals[0]

        var body: [String: Any] = ["query": query]
        if let duration = parsed.double("--duration") {
            body["duration"] = duration
        }
        WaitFlags.apply(parsed, to: &body)

        let data = try context.client.post("/longpress", body: body)
        try decodeAndPrint(data: data, pretty: context.pretty)
    }
}
