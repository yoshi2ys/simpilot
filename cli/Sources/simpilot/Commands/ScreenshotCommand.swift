import Foundation

enum ScreenshotCommand: SimpilotCommand {
    static let argSpec = ArgSpec(
        command: "screenshot",
        flags: [
            .init("--file", .string),
            .init("--scale", .string),
        ]
    )
    static let category: HelpCommands.Category = .observation
    static let synopsis = "screenshot [--file <path>] [--scale <N|native>]"
    static let description = "Capture a screenshot (default --scale 1 = 1x/point-size for AI; use 'native' for device full resolution)"
    static let example = "simpilot screenshot --file /tmp/s.png --scale native"

    static func run(context: RunContext) throws {
        let parsed = try ArgParser.parse(context.args, spec: argSpec)
        let scale = try ScaleArg.validate(parsed.string("--scale") ?? "1")

        var queryItems: [String] = ["scale=\(scale)"]
        if let filePath = parsed.string("--file") {
            guard let encoded = filePath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
                throw CLIError.invalidArgs("Invalid file path: \(filePath)")
            }
            queryItems.append("file=\(encoded)")
        }
        let path = "/screenshot?" + queryItems.joined(separator: "&")

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
