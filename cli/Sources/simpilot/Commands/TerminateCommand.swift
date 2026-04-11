import Foundation

enum TerminateCommand: SimpilotCommand {
    static let argSpec = ArgSpec(
        command: "terminate",
        positionals: [.init(name: "bundleId", required: true)]
    )
    static let category: HelpCommands.Category = .app
    static let synopsis = "terminate <bundleId>"
    static let description = "Terminate a running app"
    static let example = "simpilot terminate com.apple.Preferences"

    static func run(context: RunContext) throws {
        let parsed = try ArgParser.parse(context.args, spec: argSpec)
        let bundleId = parsed.positionals[0]
        let data = try context.client.post("/terminate", body: ["bundleId": bundleId])
        try decodeAndPrint(data: data, pretty: context.pretty)
    }
}
