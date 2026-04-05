import Foundation

enum StopCommand {
    static func run(client: HTTPClient, args: [String], pretty: Bool) throws {
        // Find and kill xcodebuild processes running AgentUITests
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

        // Kill the processes
        let pids = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        let killProcess = Process()
        killProcess.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killProcess.arguments = ["-f", "AgentUITests"]
        killProcess.standardOutput = FileHandle.nullDevice
        killProcess.standardError = FileHandle.nullDevice

        do {
            try killProcess.run()
            killProcess.waitUntilExit()
        } catch {
            throw CLIError.commandFailed("Failed to stop agent: \(error.localizedDescription)")
        }

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
