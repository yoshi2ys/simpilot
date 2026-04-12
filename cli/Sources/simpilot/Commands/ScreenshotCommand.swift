import Foundation

enum ScreenshotCommand: SimpilotCommand {
    static let argSpec = ArgSpec(
        command: "screenshot",
        flags: [
            .init("--file", .string),
            .init("--scale", .string),
            .init("--element", .string),
            .init("--format", .string),
            .init("--quality", .int),
        ]
    )
    static let category: HelpCommands.Category = .observation
    static let synopsis = "screenshot [--file <path>] [--scale <N|native>] [--element <query>] [--format png|jpeg] [--quality <0-100>]"
    static let description = "Capture a screenshot (full screen or a specific element; default --scale 1 = 1x/point-size for AI; use 'native' for device full resolution; --format jpeg reduces size)"
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
        if let format = parsed.string("--format") {
            let f = try FormatArg.validate(format)
            queryItems.append(URLQueryItem(name: "format", value: f))
        }
        if let quality = parsed.int("--quality") {
            try QualityArg.validate(quality)
            queryItems.append(URLQueryItem(name: "quality", value: "\(quality)"))
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

enum FormatArg {
    static func validate(_ value: String) throws -> String {
        let lower = value.lowercased()
        guard lower == "png" || lower == "jpeg" else {
            throw CLIError.invalidArgs("--format must be 'png' or 'jpeg' (got '\(value)')")
        }
        return lower
    }
}

enum QualityArg {
    static func validate(_ value: Int) throws {
        guard (0...100).contains(value) else {
            throw CLIError.invalidArgs("--quality must be 0-100 (got \(value))")
        }
    }
}
