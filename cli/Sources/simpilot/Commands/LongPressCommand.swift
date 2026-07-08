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
        let duration = parsed.double("--duration")
        if let duration {
            body["duration"] = duration
        }
        WaitFlags.apply(parsed, to: &body)

        // The agent waits (poll loop) and then presses, so the two budgets add.
        let waitBudget = WaitFlags.operationBudget(parsed)
        let budget: TimeInterval? = (waitBudget == nil && duration == nil)
            ? nil
            : (waitBudget ?? 0) + (duration ?? 0)
        let data = try context.client.post("/longpress", body: body, operationBudget: budget)
        try decodeAndPrint(data: data, pretty: context.pretty)
    }
}
