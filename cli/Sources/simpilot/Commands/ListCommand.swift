import Foundation

enum ListCommand {
    static func run(args: [String], pretty: Bool) throws {
        let records = AgentRegistry.load()

        var agents: [[String: Any]] = []
        for record in records {
            let c = HTTPClient(baseURL: "http://localhost:\(record.port)", timeout: 2)
            let status: String = (try? c.get("/health")) != nil ? "ready" : "unreachable"

            agents.append([
                "port": record.port,
                "pid": Int(record.pid),
                "device": record.device,
                "udid": record.udid,
                "isClone": record.isClone,
                "status": status
            ])
        }

        let result: [String: Any] = [
            "success": true,
            "data": [
                "agents": agents,
                "count": agents.count
            ] as [String: Any],
            "error": NSNull()
        ]
        printJSON(result, pretty: pretty)
    }
}
