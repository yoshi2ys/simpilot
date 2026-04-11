import Foundation

enum SourceCommand: SimpilotCommand {
    static let argSpec = ArgSpec(
        command: "source",
        flags: [
            .init("--app", .string),
        ]
    )
    static let category: HelpCommands.Category = .observation
    static let synopsis = "source [--app <bundleId>]"
    static let description = "Dump raw UI hierarchy (debugDescription)"
    static let example = "simpilot source"

    static func run(context: RunContext) throws {
        let parsed = try ArgParser.parse(context.args, spec: argSpec)

        var path = "/source"
        if let bundleId = parsed.string("--app") {
            path += "?bundleId=\(bundleId)"
        }

        let data = try context.client.get(path)
        try decodeAndPrint(data: data, pretty: context.pretty)
    }
}
