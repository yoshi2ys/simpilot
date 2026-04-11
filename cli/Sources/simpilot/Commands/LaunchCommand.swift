import Foundation

enum LaunchCommand {
    static let argSpec = ArgSpec(
        command: "launch",
        positionals: [.init(name: "bundleId", required: true)]
    )

    static func run(client: HTTPClient, args: [String], pretty: Bool) throws {
        let parsed = try ArgParser.parse(args, spec: argSpec)
        let bundleId = parsed.positionals[0]
        let data = try client.post("/launch", body: ["bundleId": bundleId])
        try decodeAndPrint(data: data, pretty: pretty)
    }
}
