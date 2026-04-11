import Foundation

enum InfoCommand {
    static let argSpec = ArgSpec(command: "info")

    static func run(client: HTTPClient, args: [String], pretty: Bool) throws {
        _ = try ArgParser.parse(args, spec: argSpec)
        let data = try client.get("/info")
        try decodeAndPrint(data: data, pretty: pretty)
    }
}
