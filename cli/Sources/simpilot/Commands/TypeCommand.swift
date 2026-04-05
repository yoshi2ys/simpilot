import Foundation

enum TypeCommand {
    static func run(client: HTTPClient, args: [String], pretty: Bool) throws {
        guard !args.isEmpty else {
            throw CLIError.invalidArgs("Usage: simpilot type <text> [--into <query>]")
        }

        // Parse: first non-option arg is text, --into <query> is optional
        var text: String?
        var query: String?
        var i = 0
        while i < args.count {
            if args[i] == "--into" {
                i += 1
                guard i < args.count else {
                    throw CLIError.invalidArgs("Usage: simpilot type <text> [--into <query>]")
                }
                query = args[i]
            } else if text == nil {
                text = args[i]
            }
            i += 1
        }

        guard let text else {
            throw CLIError.invalidArgs("Usage: simpilot type <text> [--into <query>]")
        }

        var body: [String: Any] = ["text": text]
        if let query {
            body["query"] = query
        }
        let data = try client.post("/type", body: body)
        printResponse(data: data, pretty: pretty)
    }
}
