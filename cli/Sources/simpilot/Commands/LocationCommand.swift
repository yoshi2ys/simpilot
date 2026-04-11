import Foundation

enum LocationCommand: SimpilotCommand {
    static let argSpec = ArgSpec(
        command: "location",
        positionals: [
            .init(name: "latitude", required: true),
            .init(name: "longitude", required: true),
        ]
    )
    static let category: HelpCommands.Category = .utility
    static let synopsis = "location <lat> <lon>"
    static let description = "Simulate GPS location (iOS 17+)"
    static let example = "simpilot location 35.6812 139.7671"

    static func run(context: RunContext) throws {
        let parsed = try ArgParser.parse(context.args, spec: argSpec)
        guard let latitude = Double(parsed.positionals[0]),
              let longitude = Double(parsed.positionals[1]) else {
            throw CLIError.invalidArgs("location: <latitude> and <longitude> must be numbers")
        }
        let data = try context.client.post("/location", body: [
            "latitude": latitude,
            "longitude": longitude
        ])
        try decodeAndPrint(data: data, pretty: context.pretty)
    }
}
