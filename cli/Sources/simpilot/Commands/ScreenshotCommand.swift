import Foundation

enum ScreenshotCommand {
    static func run(client: HTTPClient, args: [String], pretty: Bool) throws {
        var filePath: String?
        var i = 0

        while i < args.count {
            if args[i] == "--file" {
                i += 1
                guard i < args.count else {
                    throw CLIError.invalidArgs("Usage: simpilot screenshot [--file <path>]")
                }
                filePath = args[i]
            }
            i += 1
        }

        var path = "/screenshot"
        if let filePath {
            guard let encoded = filePath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
                throw CLIError.invalidArgs("Invalid file path: \(filePath)")
            }
            path += "?file=\(encoded)"
        }

        let data = try client.get(path)
        printResponse(data: data, pretty: pretty)
    }
}
