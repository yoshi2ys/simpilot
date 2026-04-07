import Foundation

enum TypeCommand {
    static func run(client: HTTPClient, args: [String], pretty: Bool) throws {
        guard !args.isEmpty else {
            throw CLIError.invalidArgs("Usage: simpilot type <text> [--into <query>]")
        }

        // Parse: first non-option arg is text, --into <query> is optional
        var text: String?
        var query: String?
        var method: String?
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--into":
                i += 1
                guard i < args.count else {
                    throw CLIError.invalidArgs("Usage: simpilot type <text> [--into <query>] [--method <type|paste|auto>]")
                }
                query = args[i]
            case "--method":
                i += 1
                guard i < args.count else {
                    throw CLIError.invalidArgs("Usage: simpilot type <text> [--into <query>] [--method <type|paste|auto>]")
                }
                method = args[i]
            default:
                if text == nil {
                    text = args[i]
                }
            }
            i += 1
        }

        guard let text else {
            throw CLIError.invalidArgs("Usage: simpilot type <text> [--into <query>] [--method <type|paste|auto>]")
        }

        var body: [String: Any] = ["text": text]
        if let query {
            body["query"] = query
        }
        if let method {
            body["method"] = method
        }
        let data = try client.post("/type", body: body)
        printResponse(data: data, pretty: pretty)
    }
}
