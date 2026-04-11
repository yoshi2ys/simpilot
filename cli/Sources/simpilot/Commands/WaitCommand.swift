import Foundation

enum WaitCommand {
    static let argSpec = ArgSpec(
        command: "wait",
        positionals: [.init(name: "query", required: true)],
        flags: [
            .init("--timeout", .double),
            .init("--gone", .bool),
        ]
    )

    static func run(client: HTTPClient, args: [String], pretty: Bool) throws {
        let parsed = try ArgParser.parse(args, spec: argSpec)
        let query = parsed.positionals[0]

        var body: [String: Any] = [
            "query": query,
            "exists": !parsed.bool("--gone")
        ]
        if let timeout = parsed.double("--timeout") {
            body["timeout"] = timeout
        }

        let data = try client.post("/wait", body: body)
        try decodeAndPrint(data: data, pretty: pretty)
    }
}
