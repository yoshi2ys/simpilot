import Foundation

enum PinchCommand: SimpilotCommand {
    static let argSpec = ArgSpec(
        command: "pinch",
        positionals: [.init(name: "query", required: false)],
        flags: [
            .init("--scale", .double),
            .init("--velocity", .string),
        ]
    )
    static let category: HelpCommands.Category = .interaction
    static let synopsis = "pinch [<query>] --scale <factor> [--velocity slow|default|fast]"
    static let description = "Pinch to zoom (scale > 1 = zoom in, < 1 = zoom out)"
    static let example = "simpilot pinch 'map' --scale 2.0"

    static func run(context: RunContext) throws {
        let parsed = try ArgParser.parse(context.args, spec: argSpec)

        guard let scale = parsed.double("--scale") else {
            throw CLIError.invalidArgs("pinch: --scale is required")
        }
        guard scale > 0 else {
            throw CLIError.invalidArgs("pinch: --scale must be greater than 0")
        }

        var body: [String: Any] = ["scale": scale]
        if let query = parsed.positionals.first {
            body["query"] = query
        }
        if let velocity = parsed.string("--velocity") {
            body["velocity"] = velocity
        }

        let data = try context.client.post("/pinch", body: body)
        try decodeAndPrint(data: data, pretty: context.pretty)
    }
}
