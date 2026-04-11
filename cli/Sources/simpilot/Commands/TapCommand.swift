import Foundation

enum TapCommand: SimpilotCommand {
    static let argSpec = ArgSpec(
        command: "tap",
        positionals: [.init(name: "query", required: true)],
        flags: [
            .init("--wait-until", .string),
            .init("--timeout", .double),
            .init("--poll-interval", .int),
        ]
    )
    static let category: HelpCommands.Category = .interaction
    static let synopsis = "tap <query> [--wait-until <csv>] [--timeout <s>] [--poll-interval <ms>]"
    static let description = "Tap an element by label/query"
    static let example = "simpilot tap 'General'"

    static func run(context: RunContext) throws {
        let parsed = try ArgParser.parse(context.args, spec: argSpec)
        let query = parsed.positionals[0]

        var body: [String: Any] = ["query": query]
        if let timeout = parsed.double("--timeout") {
            body["timeout_ms"] = Int(timeout * 1000)
        }
        if let waitRaw = parsed.string("--wait-until") {
            let waitUntil = waitRaw
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !waitUntil.isEmpty {
                body["wait_until"] = waitUntil
            }
        }
        if let poll = parsed.int("--poll-interval") {
            body["poll_interval_ms"] = poll
        }

        let data = try context.client.post("/tap", body: body)
        try decodeAndPrint(data: data, pretty: context.pretty)
    }
}
