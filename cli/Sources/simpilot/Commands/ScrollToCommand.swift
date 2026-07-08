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

    /// Rough per-swipe cost (seconds) — one swipe plus its settle/parse — used
    /// to size the HTTP client timeout so a long scroll loop isn't cut off at
    /// the default 30s (A5). Deliberately generous; over-waiting is harmless,
    /// under-waiting misreports a working scroll as agent_timeout.
    static let perSwipeBudget: TimeInterval = 3
    /// The agent's swipe cap when `--max-swipes` is omitted (mirrors
    /// `ScrollToHandler`'s `?? 10`), so the client budget covers the default
    /// path too rather than falling back to a bare 30s deadline.
    static let defaultMaxSwipes = 10

    /// Client-side time budget for a scroll of `maxSwipes` (or the agent
    /// default when nil). Shared with the scenario runner so both paths size
    /// the HTTP timeout identically.
    static func operationBudget(maxSwipes: Int?) -> TimeInterval {
        Double(maxSwipes ?? defaultMaxSwipes) * perSwipeBudget
    }

    static func run(context: RunContext) throws {
        let parsed = try ArgParser.parse(context.args, spec: argSpec)
        let query = parsed.positionals[0]

        var body: [String: Any] = ["query": query]
        if let direction = parsed.string("--direction") {
            body["direction"] = direction
        }
        let maxSwipes = parsed.int("--max-swipes")
        if let maxSwipes {
            guard maxSwipes > 0 else {
                throw CLIError.invalidArgs("scroll-to: --max-swipes must be greater than 0")
            }
            body["max_swipes"] = maxSwipes
        }
        if let settle = parsed.double("--settle") {
            body["settle"] = settle
        }
        let data = try context.client.post(
            "/scroll-to",
            body: body,
            operationBudget: Self.operationBudget(maxSwipes: maxSwipes)
        )
        try decodeAndPrint(data: data, pretty: context.pretty)
    }
}
