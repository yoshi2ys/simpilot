import Foundation

enum ElementsCommand {
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

    static func run(client: HTTPClient, args: [String], pretty: Bool) throws {
        let parsed = try ArgParser.parse(args, spec: argSpec)

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

        let data = try client.get(path)
        try decodeAndPrint(data: data, pretty: pretty)
    }
}
