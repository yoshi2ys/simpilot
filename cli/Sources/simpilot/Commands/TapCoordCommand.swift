import Foundation

enum TapCoordCommand {
    static let argSpec = ArgSpec(
        command: "tapcoord",
        positionals: [
            .init(name: "x", required: true),
            .init(name: "y", required: true),
        ]
    )

    static func run(client: HTTPClient, args: [String], pretty: Bool) throws {
        let parsed = try ArgParser.parse(args, spec: argSpec)
        guard let x = Double(parsed.positionals[0]),
              let y = Double(parsed.positionals[1]) else {
            throw CLIError.invalidArgs("tapcoord: <x> and <y> must be numbers")
        }
        let data = try client.post("/tapcoord", body: ["x": x, "y": y])
        try decodeAndPrint(data: data, pretty: pretty)
    }
}
