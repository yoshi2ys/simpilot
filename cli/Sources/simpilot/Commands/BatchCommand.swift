import Foundation

enum BatchCommand {
    static func run(client: HTTPClient, args: [String], pretty: Bool) throws {
        let jsonString: String
        if !args.isEmpty {
            jsonString = args.joined(separator: " ")
        } else {
            // Read from stdin
            let stdinData = FileHandle.standardInput.availableData
            guard let str = String(data: stdinData, encoding: .utf8), !str.isEmpty else {
                throw CLIError.invalidArgs("Usage: simpilot batch '<json>' or echo '<json>' | simpilot batch")
            }
            jsonString = str.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let jsonData = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw CLIError.invalidArgs("Invalid JSON input")
        }

        let data = try client.post("/batch", body: json)
        try decodeAndPrint(data: data, pretty: pretty)
    }
}
