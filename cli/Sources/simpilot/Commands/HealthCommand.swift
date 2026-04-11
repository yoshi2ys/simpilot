import Foundation

enum HealthCommand: SimpilotCommand {
    static let argSpec = ArgSpec(command: "health")
    static let category: HelpCommands.Category = .agent
    static let synopsis = "health"
    static let description = "Check if the agent is responding"
    static let example = "simpilot health"

    static func run(context: RunContext) throws {
        _ = try ArgParser.parse(context.args, spec: argSpec)
        let data = try context.client.get("/health")
        try decodeAndPrint(data: data, pretty: context.pretty)
    }
}
