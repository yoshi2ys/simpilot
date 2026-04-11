import Foundation

enum TypeCommand: SimpilotCommand {
    static let argSpec = ArgSpec(
        command: "type",
        positionals: [.init(name: "text", required: true)],
        flags: [
            .init("--into", .string),
            .init("--method", .string),
        ]
    )
    static let category: HelpCommands.Category = .interaction
    static let synopsis = "type <text> [--into <query>] [--method type|paste|auto]"
    static let description = "Type text into focused or specified element"
    static let example = "simpilot type 'hello' --into 'textField:Email'"

    static func run(context: RunContext) throws {
        let parsed = try ArgParser.parse(context.args, spec: argSpec)
        let text = parsed.positionals[0]

        var body: [String: Any] = ["text": text]
        if let query = parsed.string("--into") {
            body["query"] = query
        }
        if let method = parsed.string("--method") {
            body["method"] = method
        }
        let data = try context.client.post("/type", body: body)
        try decodeAndPrint(data: data, pretty: context.pretty)
    }
}
