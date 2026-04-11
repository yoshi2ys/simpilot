import Foundation

enum LocationCommand {
    static func run(client: HTTPClient, args: [String], pretty: Bool) throws {
        guard args.count >= 2,
              let latitude = Double(args[0]),
              let longitude = Double(args[1]) else {
            throw CLIError.invalidArgs("Usage: simpilot location <latitude> <longitude>")
        }

        let data = try client.post("/location", body: [
            "latitude": latitude,
            "longitude": longitude
        ])
        try decodeAndPrint(data: data, pretty: pretty)
    }
}
