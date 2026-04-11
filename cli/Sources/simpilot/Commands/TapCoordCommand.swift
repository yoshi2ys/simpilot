import Foundation

enum TapCoordCommand: SimpilotCommand {
    static let argSpec = ArgSpec(
        command: "tapcoord",
        positionals: [
            .init(name: "x", required: true),
            .init(name: "y", required: true),
        ]
    )
    static let category: HelpCommands.Category = .interaction
    static let synopsis = "tapcoord <x> <y>"
    static let description = "Tap at screen coordinates"
    static let example = "simpilot tapcoord 200 400"

    static func run(context: RunContext) throws {
        let parsed = try ArgParser.parse(context.args, spec: argSpec)
        guard let x = Double(parsed.positionals[0]),
              let y = Double(parsed.positionals[1]) else {
            throw CLIError.invalidArgs("tapcoord: <x> and <y> must be numbers")
        }
        let data = try context.client.post("/tapcoord", body: ["x": x, "y": y])
        try decodeAndPrint(data: data, pretty: context.pretty)
    }
}
