import Foundation

enum AppearanceCommand: SimpilotCommand {
    static let argSpec = ArgSpec(
        command: "appearance",
        positionals: [.init(name: "mode", required: false)]
    )
    static let category: HelpCommands.Category = .utility
    static let synopsis = "appearance [light|dark]"
    static let description = "Get or set appearance mode"
    static let example = "simpilot appearance dark"

    static func run(context: RunContext) throws {
        let parsed = try ArgParser.parse(context.args, spec: argSpec)

        if let mode = parsed.positionals.first {
            let data = try context.client.post("/appearance", body: ["mode": mode])
            try decodeAndPrint(data: data, pretty: context.pretty)
        } else {
            let data = try context.client.get("/appearance")
            try decodeAndPrint(data: data, pretty: context.pretty)
        }
    }
}
