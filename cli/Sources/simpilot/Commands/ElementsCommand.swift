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
            .init("--type", .string),
            .init("--contains", .string),
        ]
    )
    static let category: HelpCommands.Category = .observation
    static let synopsis = "elements [--app <bundleId>] [--depth <n>] [--level 0|1|2|3] [--actionable] [--compact] [--type <types>] [--contains <text>]"
    static let description = "List UI elements at given detail level (--type and --contains filter level 1 only)"
    static let example = "simpilot elements --level 1 --type button,switch --contains Settings"

    /// Build the GET path from CLI args. Exposed for testing.
    static func buildPath(from args: [String]) throws -> String {
        let parsed = try ArgParser.parse(args, spec: argSpec)

        var components = URLComponents()
        components.path = "/elements"
        var queryItems: [URLQueryItem] = []
        if let bundleId = parsed.string("--app") {
            queryItems.append(URLQueryItem(name: "bundleId", value: bundleId))
        }
        if let depth = parsed.int("--depth") {
            queryItems.append(URLQueryItem(name: "depth", value: "\(depth)"))
        }
        if let level = parsed.int("--level") {
            queryItems.append(URLQueryItem(name: "level", value: "\(level)"))
        } else if parsed.bool("--actionable") {
            queryItems.append(URLQueryItem(name: "mode", value: "actionable"))
        } else if parsed.bool("--compact") {
            queryItems.append(URLQueryItem(name: "mode", value: "compact"))
        }
        if let type = parsed.string("--type") {
            queryItems.append(URLQueryItem(name: "type", value: type))
        }
        if let contains = parsed.string("--contains") {
            queryItems.append(URLQueryItem(name: "contains", value: contains))
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        return components.string ?? "/elements"
    }

    static func run(context: RunContext) throws {
        let path = try buildPath(from: context.args)
        let data = try context.client.get(path)
        try decodeAndPrint(data: data, pretty: context.pretty)
    }
}
