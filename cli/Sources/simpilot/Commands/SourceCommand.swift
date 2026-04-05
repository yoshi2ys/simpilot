import Foundation

enum SourceCommand {
    static func run(client: HTTPClient, args: [String], pretty: Bool) throws {
        var bundleId: String?
        var i = 0

        while i < args.count {
            if args[i] == "--app" {
                i += 1
                guard i < args.count else {
                    throw CLIError.invalidArgs("Usage: simpilot source [--app <bundleId>]")
                }
                bundleId = args[i]
            }
            i += 1
        }

        var path = "/source"
        if let bundleId {
            path += "?bundleId=\(bundleId)"
        }

        let data = try client.get(path)
        printResponse(data: data, pretty: pretty)
    }
}
