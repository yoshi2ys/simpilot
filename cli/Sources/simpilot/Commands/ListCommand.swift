import Foundation

enum ListCommand: SimpilotCommand {
    static let argSpec = ArgSpec(command: "list")
    static let category: HelpCommands.Category = .agent
    static let synopsis = "list"
    static let description = "List running agents"
    static let example = "simpilot list"

    static func run(context: RunContext) throws {
        _ = try ArgParser.parse(context.args, spec: argSpec)
        let records = AgentRegistry.load()

        var agents: [[String: Any]] = []
        for record in records {
            let c = HTTPClient(baseURL: record.baseURL, timeout: 2)
            let status: String = (try? c.get("/health")) != nil ? "ready" : "unreachable"

            var entry: [String: Any] = [
                "port": record.port,
                "pid": Int(record.pid),
                "device": record.device,
                "udid": record.udid,
                "isClone": record.isClone,
                "status": status
            ]
            if record.isPhysical {
                entry["host"] = record.host
                entry["isPhysical"] = true
            }
            agents.append(entry)
        }

        let result: [String: Any] = [
            "success": true,
            "data": [
                "agents": agents,
                "count": agents.count
            ] as [String: Any],
            "error": NSNull()
        ]
        printJSON(result, pretty: context.pretty)
    }
}
