import Foundation

enum AppearanceCommand {
    static let argSpec = ArgSpec(
        command: "appearance",
        positionals: [.init(name: "mode", required: false)]
    )

    static func run(client: HTTPClient, args: [String], pretty: Bool) throws {
        let parsed = try ArgParser.parse(args, spec: argSpec)

        if let mode = parsed.positionals.first {
            let data = try client.post("/appearance", body: ["mode": mode])
            try decodeAndPrint(data: data, pretty: pretty)
        } else {
            let data = try client.get("/appearance")
            try decodeAndPrint(data: data, pretty: pretty)
        }
    }
}
