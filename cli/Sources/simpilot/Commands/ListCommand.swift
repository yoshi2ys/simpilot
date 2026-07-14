import Foundation

enum ListCommand: SimpilotCommand {
    static let argSpec = ArgSpec(command: "list")
    static let category: HelpCommands.Category = .agent
    static let synopsis = "list"
    static let description = "List running agents"
    static let example = "simpilot list"

    static func run(context: RunContext) throws {
        _ = try ArgParser.parse(context.args, spec: argSpec)
        let records = try AgentRegistry.load()

        var agents: [[String: Any]] = []
        for record in records {
            // A 401 still returns bytes, so "we got a reply" is not "ready" —
            // that would mask a foreign agent squatting the port.
            let c = HTTPClient(baseURL: record.baseURL, timeout: 2, token: record.token)
            let reply = try? c.get("/health")
            let status: String
            switch reply {
            case .some(let data) where StartCommand.isHealthyEnvelope(data): status = "ready"
            case .some: status = "unauthorized"
            case .none: status = "unreachable"
            }

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
