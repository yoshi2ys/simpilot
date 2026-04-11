import Foundation

enum ElementsCommand: SimpilotCommand {
    static let argSpec = ArgSpec(
        command: "elements",
        flags: [
            .init("--app", .string),
            .init("--depth", .int),
            .init("--level", .int),
            .init("--actionable", .bool),
            .init("--compact", .bool),
        ]
    )
    static let category: HelpCommands.Category = .observation
    static let synopsis = "elements [--app <bundleId>] [--depth <n>] [--level 0|1|2|3] [--actionable] [--compact]"
    static let description = "List UI elements at given detail level"
    static let example = "simpilot elements --level 1"

    static func run(context: RunContext) throws {
        let parsed = try ArgParser.parse(context.args, spec: argSpec)

        var queryItems: [String] = []
        if let bundleId = parsed.string("--app") {
            queryItems.append("bundleId=\(bundleId)")
        }
        if let depth = parsed.int("--depth") {
            queryItems.append("depth=\(depth)")
        }
        // --level takes precedence over --actionable/--compact
        if let level = parsed.int("--level") {
            queryItems.append("level=\(level)")
        } else if parsed.bool("--actionable") {
            queryItems.append("mode=actionable")
        } else if parsed.bool("--compact") {
            queryItems.append("mode=compact")
        }

        var path = "/elements"
        if !queryItems.isEmpty {
            path += "?" + queryItems.joined(separator: "&")
        }

        let data = try context.client.get(path)
        try decodeAndPrint(data: data, pretty: context.pretty)
    }
}
