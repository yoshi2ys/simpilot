import Foundation

enum SliderCommand: SimpilotCommand {
    static let argSpec = ArgSpec(
        command: "slider",
        positionals: [.init(name: "query", required: false)],
        flags: [
            .init("--value", .double),
        ]
    )
    static let category: HelpCommands.Category = .interaction
    static let synopsis = "slider [<query>] --value <0.0-1.0>"
    static let description = "Adjust a slider to a normalized position (0.0 = min, 1.0 = max)"
    static let example = "simpilot slider 'slider:Volume' --value 0.5"

    static func run(context: RunContext) throws {
        let parsed = try ArgParser.parse(context.args, spec: argSpec)

        guard let value = parsed.double("--value") else {
            throw CLIError.invalidArgs("slider: --value is required")
        }
        guard value >= 0 && value <= 1 else {
            throw CLIError.invalidArgs("slider: --value must be between 0.0 and 1.0")
        }

        var body: [String: Any] = ["value": value]
        if let query = parsed.positionals.first {
            body["query"] = query
        }

        let data = try context.client.post("/slider", body: body)
        try decodeAndPrint(data: data, pretty: context.pretty)
    }
}
