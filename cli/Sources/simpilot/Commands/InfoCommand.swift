import Foundation

enum InfoCommand: SimpilotCommand {
    static let argSpec = ArgSpec(command: "info")
    static let category: HelpCommands.Category = .agent
    static let synopsis = "info"
    static let description = "Show agent and device info"
    static let example = "simpilot info"

    static func run(context: RunContext) throws {
        _ = try ArgParser.parse(context.args, spec: argSpec)
        let data = try context.client.get("/info")
        try decodeAndPrint(data: data, pretty: context.pretty)
    }
}
