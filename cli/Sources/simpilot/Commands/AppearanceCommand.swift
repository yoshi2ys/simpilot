import Foundation

enum AppearanceCommand {
    static func run(client: HTTPClient, args: [String], pretty: Bool) throws {
        if args.isEmpty {
            // GET current appearance
            let data = try client.get("/appearance")
            printResponse(data: data, pretty: pretty)
        } else {
            // SET appearance
            let mode = args[0]
            let data = try client.post("/appearance", body: ["mode": mode])
            printResponse(data: data, pretty: pretty)
        }
    }
}
