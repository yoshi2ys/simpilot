import Foundation

enum SourceCommand {
    static let argSpec = ArgSpec(
        command: "source",
        flags: [
            .init("--app", .string),
        ]
    )

    static func run(client: HTTPClient, args: [String], pretty: Bool) throws {
        let parsed = try ArgParser.parse(args, spec: argSpec)

        var path = "/source"
        if let bundleId = parsed.string("--app") {
            path += "?bundleId=\(bundleId)"
        }

        let data = try client.get(path)
        try decodeAndPrint(data: data, pretty: pretty)
    }
}
