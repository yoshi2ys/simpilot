import Foundation

enum StartCommand {
    static func run(client: HTTPClient, args: [String], pretty: Bool, port: Int) throws {
        var deviceName = "iPhone 17 Pro"
        var i = 0

        while i < args.count {
            if args[i] == "--device" {
                i += 1
                guard i < args.count else {
                    throw CLIError.invalidArgs("Usage: simpilot start [--device <name>]")
                }
                deviceName = args[i]
            }
            i += 1
        }

        // Find the project directory (look for xcodeproj relative to the CLI binary or CWD)
        let projectDir = findProjectDirectory()

        // Build the xcodebuild command
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        process.arguments = [
            "test",
            "-project", projectDir + "/AgentApp.xcodeproj",
            "-scheme", "AgentUITests",
            "-destination", "platform=\(platformForDevice(deviceName)),name=\(deviceName)",
            "-only-testing:AgentUITests",
            "-parallel-testing-enabled", "NO"
        ]

        // Set environment to pass port
        var env = ProcessInfo.processInfo.environment
        env["SIMPILOT_PORT"] = String(port)
        process.environment = env

        // Redirect output to /dev/null to avoid cluttering the terminal
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw CLIError.commandFailed("Failed to start xcodebuild: \(error.localizedDescription)")
        }

        let pid = process.processIdentifier

        // Poll /health until the agent is ready (max 60 seconds)
        let startTime = Date()
        let maxWait: TimeInterval = 60
        var agentReady = false

        while Date().timeIntervalSince(startTime) < maxWait {
            Thread.sleep(forTimeInterval: 1)
            if let _ = try? client.get("/health") {
                agentReady = true
                break
            }
        }

        if agentReady {
            let result: [String: Any] = [
                "success": true,
                "data": [
                    "pid": Int(pid),
                    "device": deviceName,
                    "port": port,
                    "message": "Agent started successfully"
                ] as [String: Any],
                "error": NSNull()
            ]
            printJSON(result, pretty: pretty)
        } else {
            // Kill the process if agent never became ready
            process.terminate()
            throw CLIError.commandFailed("Agent failed to start within 60 seconds")
        }
    }

    private static func platformForDevice(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("vision") {
            return "visionOS Simulator"
        } else if lower.contains("apple tv") {
            return "tvOS Simulator"
        } else if lower.contains("apple watch") {
            return "watchOS Simulator"
        }
        return "iOS Simulator"
    }

    private static func findProjectDirectory() -> String {
        // Walk up from the current working directory looking for agent/AgentApp.xcodeproj
        var dir = FileManager.default.currentDirectoryPath
        for _ in 0..<10 {
            let projectPath = dir + "/agent/AgentApp.xcodeproj"
            if FileManager.default.fileExists(atPath: projectPath) {
                return dir + "/agent"
            }
            // Also check if we're already inside the agent dir
            let directPath = dir + "/AgentApp.xcodeproj"
            if FileManager.default.fileExists(atPath: directPath) {
                return dir
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return FileManager.default.currentDirectoryPath
    }
}
