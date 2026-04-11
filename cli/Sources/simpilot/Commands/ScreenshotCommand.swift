import Foundation

enum ScreenshotCommand {
    static let argSpec = ArgSpec(
        command: "screenshot",
        flags: [
            .init("--file", .string),
            .init("--scale", .string),
        ]
    )

    static func run(client: HTTPClient, args: [String], pretty: Bool) throws {
        let parsed = try ArgParser.parse(args, spec: argSpec)
        let scale = try ScaleArg.validate(parsed.string("--scale") ?? "1")

        var queryItems: [String] = ["scale=\(scale)"]
        if let filePath = parsed.string("--file") {
            guard let encoded = filePath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
                throw CLIError.invalidArgs("Invalid file path: \(filePath)")
            }
            queryItems.append("file=\(encoded)")
        }
        let path = "/screenshot?" + queryItems.joined(separator: "&")

        let data = try client.get(path)
        try decodeAndPrint(data: data, pretty: pretty)
    }
}

enum ScaleArg {
    static func validate(_ value: String) throws -> String {
        if value == "native" { return "native" }
        if let n = Double(value), n > 0 { return value }
        throw CLIError.invalidArgs("--scale must be a positive number or 'native' (got '\(value)')")
    }
}
