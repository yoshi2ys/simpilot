import Foundation

enum ActivateCommand: SimpilotCommand {
    static let argSpec = ArgSpec(
        command: "activate",
        positionals: [.init(name: "bundleId", required: true)]
    )
    static let category: HelpCommands.Category = .app
    static let synopsis = "activate <bundleId>"
    static let description = "Bring a running app to the foreground"
    static let example = "simpilot activate com.apple.Preferences"

    static func run(context: RunContext) throws {
        let parsed = try ArgParser.parse(context.args, spec: argSpec)
        let bundleId = parsed.positionals[0]
        let data = try context.client.post("/activate", body: ["bundleId": bundleId])
        try decodeAndPrint(data: data, pretty: context.pretty)
    }
}
