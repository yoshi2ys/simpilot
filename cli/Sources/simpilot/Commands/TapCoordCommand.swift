import Foundation

enum TapCoordCommand {
    static func run(client: HTTPClient, args: [String], pretty: Bool) throws {
        guard args.count >= 2,
              let x = Double(args[0]),
              let y = Double(args[1]) else {
            throw CLIError.invalidArgs("Usage: simpilot tapcoord <x> <y>")
        }
        let data = try client.post("/tapcoord", body: ["x": x, "y": y])
        try decodeAndPrint(data: data, pretty: pretty)
    }
}
