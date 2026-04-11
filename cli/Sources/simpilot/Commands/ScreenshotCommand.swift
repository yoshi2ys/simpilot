import Foundation

enum ScreenshotCommand {
    static func run(client: HTTPClient, args: [String], pretty: Bool) throws {
        var filePath: String?
        var scale: String = "1"
        var i = 0

        while i < args.count {
            switch args[i] {
            case "--file":
                i += 1
                guard i < args.count else {
                    throw CLIError.invalidArgs("Usage: simpilot screenshot [--file <path>] [--scale <N|native>]")
                }
                filePath = args[i]
            case "--scale":
                i += 1
                guard i < args.count else {
                    throw CLIError.invalidArgs("--scale requires a positive number or 'native'")
                }
                scale = try ScaleArg.validate(args[i])
            default:
                break
            }
            i += 1
        }

        var queryItems: [String] = ["scale=\(scale)"]
        if let filePath {
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
