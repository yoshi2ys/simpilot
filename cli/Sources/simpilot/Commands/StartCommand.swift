import Foundation

enum StartCommand {
    private enum MultiMode {
        case clone(Int)
        case create(Int)
    }

    static func run(args: [String], pretty: Bool, port: Int) throws {
        var deviceName = "iPhone 17 Pro"
        var multiMode: MultiMode? = nil
        var i = 0

        while i < args.count {
            switch args[i] {
            case "--device":
                i += 1
                guard i < args.count else {
                    throw CLIError.invalidArgs("Usage: simpilot start [--device <name>] [--clone [N]] [--create [N]]")
                }
                deviceName = args[i]
            case "--clone":
                let n = parseOptionalCount(args: args, index: &i)
                multiMode = .clone(n)
            case "--create":
                let n = parseOptionalCount(args: args, index: &i)
                multiMode = .create(n)
            default:
                break
            }
            i += 1
        }

        switch multiMode {
        case .clone(let count):
            try runMulti(deviceName: deviceName, count: count, useClone: true, pretty: pretty)
        case .create(let count):
            try runMulti(deviceName: deviceName, count: count, useClone: false, pretty: pretty)
        case nil:
            try runSingle(deviceName: deviceName, port: port, pretty: pretty)
        }
    }

    // MARK: - Single Agent

    private static func runSingle(deviceName: String, port: Int, pretty: Bool) throws {
        let udid = (try? SimctlHelper.findDeviceUDID(name: deviceName)) ?? ""
        let destination = "platform=\(platformForDevice(deviceName)),name=\(deviceName)"
        let process = try launchXcodebuild(destination: destination, port: port, udid: udid)
        let pid = process.processIdentifier

        guard waitForHealth(port: port) else {
            process.terminate()
            throw CLIError.commandFailed("Agent failed to start within 60 seconds")
        }

        AgentRegistry.add(AgentRecord(
            port: port, pid: pid, udid: udid,
            device: deviceName, isClone: false, startedAt: Date()
        ))

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
    }

    // MARK: - Multi Agent (clone or create)

    private static func runMulti(deviceName: String, count: Int, useClone: Bool, pretty: Bool) throws {
        let (runtime, sourceInfo) = try SimctlHelper.findDevice(name: deviceName)
        var started: [[String: Any]] = []

        for _ in 0..<count {
            let port = try AgentRegistry.findAvailablePort()
            let newName = useClone
                ? "Clone of \(deviceName) (\(port))"
                : "New \(deviceName) (\(port))"

            let newUDID: String
            if useClone {
                newUDID = try SimctlHelper.cloneDevice(sourceUDID: sourceInfo.udid, newName: newName)
            } else {
                newUDID = try SimctlHelper.createDevice(
                    newName: newName,
                    deviceType: sourceInfo.deviceTypeIdentifier,
                    runtime: runtime
                )
            }
            try SimctlHelper.bootDevice(udid: newUDID)

            let process: Process
            do {
                process = try launchXcodebuild(
                    destination: "id=\(newUDID)",
                    port: port,
                    udid: newUDID
                )
            } catch {
                SimctlHelper.deleteClone(udid: newUDID)
                throw error
            }

            let pid = process.processIdentifier

            guard waitForHealth(port: port) else {
                process.terminate()
                SimctlHelper.deleteClone(udid: newUDID)
                throw CLIError.commandFailed("Agent on port \(port) failed to start within 60 seconds")
            }

            AgentRegistry.add(AgentRecord(
                port: port, pid: pid, udid: newUDID,
                device: newName, isClone: true, startedAt: Date()
            ))

            started.append([
                "pid": Int(pid),
                "device": newName,
                "port": port,
                "udid": newUDID
            ])
        }

        let result: [String: Any] = [
            "success": true,
            "data": [
                "agents": started,
                "count": started.count,
                "message": "\(started.count) agent(s) started"
            ] as [String: Any],
            "error": NSNull()
        ]
        printJSON(result, pretty: pretty)
    }

    // MARK: - Helpers

    private static func parseOptionalCount(args: [String], index i: inout Int) -> Int {
        if i + 1 < args.count, let n = Int(args[i + 1]), n > 0 {
            i += 1
            return n
        }
        return 1
    }

    private static func launchXcodebuild(
        destination: String,
        port: Int,
        udid: String? = nil
    ) throws -> Process {
        let projectDir = try findProjectDirectory()

        if let udid = udid {
            AgentRegistry.writePortFile(udid: udid, port: port)
        }

        let arguments = [
            "test",
            "-project", projectDir + "/AgentApp.xcodeproj",
            "-scheme", "AgentUITests",
            "-destination", destination,
            "-only-testing:AgentUITests",
            "-parallel-testing-enabled", "NO"
        ]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        env["SIMPILOT_PORT"] = String(port)
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw CLIError.commandFailed("Failed to start xcodebuild: \(error.localizedDescription)")
        }

        return process
    }

    private static func waitForHealth(port: Int, timeout: TimeInterval = 60) -> Bool {
        let client = HTTPClient(baseURL: "http://localhost:\(port)", timeout: 5)
        let startTime = Date()
        while Date().timeIntervalSince(startTime) < timeout {
            Thread.sleep(forTimeInterval: 1)
            if let _ = try? client.get("/health") {
                return true
            }
        }
        return false
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

    private static func findProjectDirectory() throws -> String {
        var dir = FileManager.default.currentDirectoryPath
        for _ in 0..<10 {
            let projectPath = dir + "/agent/AgentApp.xcodeproj"
            if FileManager.default.fileExists(atPath: projectPath) {
                return dir + "/agent"
            }
            let directPath = dir + "/AgentApp.xcodeproj"
            if FileManager.default.fileExists(atPath: directPath) {
                return dir
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        throw CLIError.commandFailed("AgentApp.xcodeproj not found")
    }
}
