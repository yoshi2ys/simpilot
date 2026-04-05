import Foundation

enum InfoCommand {
    static func run(client: HTTPClient, args: [String], pretty: Bool) throws {
        let data = try client.get("/info")
        printResponse(data: data, pretty: pretty)
    }
}
