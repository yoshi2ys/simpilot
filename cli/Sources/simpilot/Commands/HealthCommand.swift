import Foundation

enum HealthCommand {
    static func run(client: HTTPClient, args: [String], pretty: Bool) throws {
        let data = try client.get("/health")
        try decodeAndPrint(data: data, pretty: pretty)
    }
}
