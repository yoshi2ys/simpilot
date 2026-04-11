import Foundation

enum LaunchCommand {
    static func run(client: HTTPClient, args: [String], pretty: Bool) throws {
        guard let bundleId = args.first else {
            throw CLIError.invalidArgs("Usage: simpilot launch <bundleId>")
        }
        let data = try client.post("/launch", body: ["bundleId": bundleId])
        try decodeAndPrint(data: data, pretty: pretty)
    }
}
