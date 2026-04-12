import Foundation

enum DragCommand: SimpilotCommand {
    static let argSpec = ArgSpec(
        command: "drag",
        positionals: [.init(name: "query", required: false)],
        flags: [
            .init("--to", .string),
            .init("--to-x", .double),
            .init("--to-y", .double),
            .init("--from-x", .double),
            .init("--from-y", .double),
            .init("--duration", .double),
        ]
    )
    static let category: HelpCommands.Category = .interaction
    static let synopsis = "drag [<query>] [--to <query>] [--to-x <x> --to-y <y>] [--from-x <x> --from-y <y>] [--duration <s>]"
    static let description = "Drag from one element/coordinate to another"
    static let example = "simpilot drag 'item-1' --to 'item-3'"

    static func run(context: RunContext) throws {
        let parsed = try ArgParser.parse(context.args, spec: argSpec)
        let query = parsed.positionals.first
        let toQuery = parsed.string("--to")
        let toX = parsed.double("--to-x")
        let toY = parsed.double("--to-y")
        let fromX = parsed.double("--from-x")
        let fromY = parsed.double("--from-y")

        // Validate coordinate pairs are complete
        if (toX != nil) != (toY != nil) {
            throw CLIError.invalidArgs("drag: --to-x and --to-y must be specified together")
        }
        if (fromX != nil) != (fromY != nil) {
            throw CLIError.invalidArgs("drag: --from-x and --from-y must be specified together")
        }

        // Validate mutual exclusivity
        if query != nil && (fromX != nil || fromY != nil) {
            throw CLIError.invalidArgs("drag: cannot specify both <query> and --from-x/--from-y")
        }
        if toQuery != nil && (toX != nil || toY != nil) {
            throw CLIError.invalidArgs("drag: cannot specify both --to and --to-x/--to-y")
        }

        // Validate destination
        guard toQuery != nil || (toX != nil && toY != nil) else {
            throw CLIError.invalidArgs("drag: must specify --to <query> or both --to-x and --to-y")
        }

        // Validate source
        guard query != nil || (fromX != nil && fromY != nil) else {
            throw CLIError.invalidArgs("drag: must specify <query> or both --from-x and --from-y")
        }

        // Validate duration
        if let duration = parsed.double("--duration"), duration < 0 {
            throw CLIError.invalidArgs("drag: --duration must be >= 0")
        }

        var body: [String: Any] = [:]
        if let query { body["query"] = query }
        if let toQuery { body["to_query"] = toQuery }
        if let toX { body["to_x"] = toX }
        if let toY { body["to_y"] = toY }
        if let fromX { body["from_x"] = fromX }
        if let fromY { body["from_y"] = fromY }
        if let duration = parsed.double("--duration") {
            body["duration"] = duration
        }

        let data = try context.client.post("/drag", body: body)
        try decodeAndPrint(data: data, pretty: context.pretty)
    }
}
