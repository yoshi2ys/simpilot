import Foundation

enum ScreenshotCommand: SimpilotCommand {
    static let argSpec = ArgSpec(
        command: "screenshot",
        flags: [
            .init("--file", .string),
            .init("--scale", .string),
            .init("--element", .string),
        ]
    )
    static let category: HelpCommands.Category = .observation
    static let synopsis = "screenshot [--file <path>] [--scale <N|native>] [--element <query>]"
    static let description = "Capture a screenshot (full screen or a specific element; default --scale 1 = 1x/point-size for AI; use 'native' for device full resolution)"
    static let example = "simpilot screenshot --file /tmp/s.png --scale native"

    /// Build the GET path from CLI args. Exposed for testing.
    static func buildPath(from args: [String]) throws -> String {
        let parsed = try ArgParser.parse(args, spec: argSpec)
        let scale = try ScaleArg.validate(parsed.string("--scale") ?? "1")

        var components = URLComponents()
        components.path = "/screenshot"
        var queryItems: [URLQueryItem] = [URLQueryItem(name: "scale", value: scale)]
        if let file = parsed.string("--file") {
            queryItems.append(URLQueryItem(name: "file", value: file))
        }
        if let element = parsed.string("--element") {
            queryItems.append(URLQueryItem(name: "element", value: element))
        }
        components.queryItems = queryItems
        return components.string ?? "/screenshot"
    }

    static func run(context: RunContext) throws {
        let path = try buildPath(from: context.args)
        let data = try context.client.get(path)
        try decodeAndPrint(data: data, pretty: context.pretty)
    }
}

enum ScaleArg {
    static func validate(_ value: String) throws -> String {
        if value == "native" { return "native" }
        if let n = Double(value), n > 0 { return value }
        throw CLIError.invalidArgs("--scale must be a positive number or 'native' (got '\(value)')")
    }
}
