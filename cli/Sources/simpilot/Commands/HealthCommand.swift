import Foundation

enum HealthCommand {
    static let argSpec = ArgSpec(command: "health")

    static func run(client: HTTPClient, args: [String], pretty: Bool) throws {
        _ = try ArgParser.parse(args, spec: argSpec)
        let data = try client.get("/health")
        try decodeAndPrint(data: data, pretty: pretty)
    }
}
