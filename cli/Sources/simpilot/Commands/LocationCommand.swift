import Foundation

enum LocationCommand {
    static let argSpec = ArgSpec(
        command: "location",
        positionals: [
            .init(name: "latitude", required: true),
            .init(name: "longitude", required: true),
        ]
    )

    static func run(client: HTTPClient, args: [String], pretty: Bool) throws {
        let parsed = try ArgParser.parse(args, spec: argSpec)
        guard let latitude = Double(parsed.positionals[0]),
              let longitude = Double(parsed.positionals[1]) else {
            throw CLIError.invalidArgs("location: <latitude> and <longitude> must be numbers")
        }
        let data = try client.post("/location", body: [
            "latitude": latitude,
            "longitude": longitude
        ])
        try decodeAndPrint(data: data, pretty: pretty)
    }
}
