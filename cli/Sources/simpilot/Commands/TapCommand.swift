import Foundation

enum TapCommand {
    static func run(client: HTTPClient, args: [String], pretty: Bool) throws {
        guard let query = args.first else {
            throw CLIError.invalidArgs("Usage: simpilot tap <query>")
        }
        let data = try client.post("/tap", body: ["query": query])
        printResponse(data: data, pretty: pretty)
    }
}
