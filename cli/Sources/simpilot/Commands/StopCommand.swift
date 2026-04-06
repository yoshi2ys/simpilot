import Foundation

enum StopCommand {
    static func run(args: [String], pretty: Bool, port: Int) throws {
        if args.contains("--all") {
            stopAllAgents(pretty: pretty)
        } else {
            try stopAgent(port: port, pretty: pretty)
        }
    }

    // MARK: - Stop Single Agent

    private static func stopAgent(port: Int, pretty: Bool) throws {
        if let record = AgentRegistry.remove(port: port) {
            teardownAgent(record)

            let result: [String: Any] = [
                "success": true,
                "data": [
                    "message": "Agent stopped",
                    "port": record.port,
                    "pid": Int(record.pid),
                    "cloneDeleted": record.isClone
                ] as [String: Any],
                "error": NSNull()
            ]
            printJSON(result, pretty: pretty)
            return
        }

        try legacyStop(pretty: pretty)
    }

    // MARK: - Stop All Agents

    private static func stopAllAgents(pretty: Bool) {
        let records = AgentRegistry.removeAll()

        var stopped: [[String: Any]] = []
        for record in records {
            teardownAgent(record)
            stopped.append([
                "port": record.port,
                "pid": Int(record.pid),
                "cloneDeleted": record.isClone
            ])
        }

        pkillAgentUITests()

        let result: [String: Any] = [
            "success": true,
            "data": [
                "message": stopped.isEmpty ? "No running agents found" : "\(stopped.count) agent(s) stopped",
                "agents": stopped
            ] as [String: Any],
            "error": NSNull()
        ]
        printJSON(result, pretty: pretty)
    }

    // MARK: - Helpers

    private static func teardownAgent(_ record: AgentRecord) {
        kill(record.pid, SIGTERM)
        if !record.isPhysical {
            AgentRegistry.removePortFile(udid: record.udid)
        }
        if record.isClone {
            SimctlHelper.deleteClone(udid: record.udid)
        }
    }

    private static func pkillAgentUITests() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-f", "AgentUITests"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: - Legacy Fallback

    private static func legacyStop(pretty: Bool) throws {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", "AgentUITests"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw CLIError.commandFailed("Failed to find agent process: \(error.localizedDescription)")
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if output.isEmpty {
            let result: [String: Any] = [
                "success": true,
                "data": ["message": "No running agent found"],
                "error": NSNull()
            ]
            printJSON(result, pretty: pretty)
            return
        }

        let pids = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        pkillAgentUITests()

        let result: [String: Any] = [
            "success": true,
            "data": [
                "message": "Agent stopped",
                "killed_pids": pids
            ] as [String: Any],
            "error": NSNull()
        ]
        printJSON(result, pretty: pretty)
    }
}
