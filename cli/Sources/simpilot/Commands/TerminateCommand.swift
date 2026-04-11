import Foundation

enum TerminateCommand {
    static func run(client: HTTPClient, args: [String], pretty: Bool) throws {
        guard let bundleId = args.first else {
            throw CLIError.invalidArgs("Usage: simpilot terminate <bundleId>")
        }
        let data = try client.post("/terminate", body: ["bundleId": bundleId])
        try decodeAndPrint(data: data, pretty: pretty)
    }
}
