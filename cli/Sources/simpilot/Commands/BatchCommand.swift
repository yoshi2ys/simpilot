import Foundation

enum BatchCommand: SimpilotCommand {
    static let argSpec = ArgSpec(
        command: "batch",
        positionals: [.init(name: "json", required: false)],
        allowsExtraPositionals: true
    )
    static let category: HelpCommands.Category = .utility
    static let synopsis = "batch <json>"
    static let description = "Run multiple commands in one request"
    static let example = #"simpilot batch '{"commands":[{"method":"GET","path":"/health"}]}'"#

    static func run(context: RunContext) throws {
        let parsed = try ArgParser.parse(context.args, spec: argSpec)

        let jsonString: String
        if !parsed.positionals.isEmpty {
            jsonString = parsed.positionals.joined(separator: " ")
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

        let data = try context.client.post("/batch", body: json)
        try decodeAndPrint(data: data, pretty: context.pretty)
    }
}
