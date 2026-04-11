import Foundation

enum ActivateCommand {
    static func run(client: HTTPClient, args: [String], pretty: Bool) throws {
        guard let bundleId = args.first else {
            throw CLIError.invalidArgs("Usage: simpilot activate <bundleId>")
        }
        let data = try client.post("/activate", body: ["bundleId": bundleId])
        try decodeAndPrint(data: data, pretty: pretty)
    }
}
