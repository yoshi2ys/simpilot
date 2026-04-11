import Foundation

enum TypeCommand {
    static let argSpec = ArgSpec(
        command: "type",
        positionals: [.init(name: "text", required: true)],
        flags: [
            .init("--into", .string),
            .init("--method", .string),
        ]
    )

    static func run(client: HTTPClient, args: [String], pretty: Bool) throws {
        let parsed = try ArgParser.parse(args, spec: argSpec)
        let text = parsed.positionals[0]

        var body: [String: Any] = ["text": text]
        if let query = parsed.string("--into") {
            body["query"] = query
        }
        if let method = parsed.string("--method") {
            body["method"] = method
        }
        let data = try client.post("/type", body: body)
        try decodeAndPrint(data: data, pretty: pretty)
    }
}
