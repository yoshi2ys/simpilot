import Foundation

enum LaunchCommand: SimpilotCommand {
    static let argSpec = ArgSpec(
        command: "launch",
        positionals: [.init(name: "bundleId", required: true)]
    )
    static let category: HelpCommands.Category = .app
    static let synopsis = "launch <bundleId>"
    static let description = "Launch an app by bundle ID"
    static let example = "simpilot launch com.apple.Preferences"

    static func run(context: RunContext) throws {
        let parsed = try ArgParser.parse(context.args, spec: argSpec)
        let bundleId = parsed.positionals[0]
        let data = try context.client.post("/launch", body: ["bundleId": bundleId])
        try decodeAndPrint(data: data, pretty: context.pretty)
    }
}
