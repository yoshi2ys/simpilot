import Foundation

enum SwipeCommand {
    static let argSpec = ArgSpec(
        command: "swipe",
        positionals: [.init(name: "direction", required: true)],
        flags: [
            .init("--on", .string),
            .init("--velocity", .string),
        ]
    )

    static func run(client: HTTPClient, args: [String], pretty: Bool) throws {
        let parsed = try ArgParser.parse(args, spec: argSpec)
        let direction = parsed.positionals[0]

        var body: [String: Any] = ["direction": direction]
        if let query = parsed.string("--on") {
            body["query"] = query
        }
        if let velocity = parsed.string("--velocity") {
            body["velocity"] = velocity
        }
        let data = try client.post("/swipe", body: body)
        try decodeAndPrint(data: data, pretty: pretty)
    }
}
