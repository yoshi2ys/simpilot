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

        // Resolve device: try simulator first, then physical device
        let resolved = resolveDevice(name: deviceName)

        switch multiMode {
        case .clone(let count):
            if case .physical = resolved {
                throw CLIError.invalidArgs("--clone and --create are not supported for physical devices")
            }
            try runMulti(deviceName: deviceName, count: count, useClone: true, pretty: pretty)
        case .create(let count):
            if case .physical = resolved {
                throw CLIError.invalidArgs("--clone and --create are not supported for physical devices")
            }
            try runMulti(deviceName: deviceName, count: count, useClone: false, pretty: pretty)
        case nil:
            try runSingle(deviceName: deviceName, port: port, resolved: resolved, pretty: pretty)
        }
    }

    private enum ResolvedDevice {
        case simulator(udid: String, platform: String)
        case physical(device: DeviceHelper.PhysicalDevice)
        case unknown
    }

    private static func resolveDevice(name: String) -> ResolvedDevice {
        // Try simulator first (preserves existing behavior)
        if let udid = try? SimctlHelper.findDeviceUDID(name: name) {
            return .simulator(udid: udid, platform: platformForDevice(name))
        }
        // Try physical device
        if let device = try? DeviceHelper.findDevice(name: name) {
            return .physical(device: device)
        }
        return .unknown
    }

    // MARK: - Single Agent

    private static func runSingle(deviceName: String, port: Int, resolved: ResolvedDevice, pretty: Bool) throws {
        let destination: String
        let udid: String
        let isPhysical: Bool

        switch resolved {
        case .simulator(let simUDID, let platform):
            destination = "platform=\(platform),name=\(deviceName)"
            udid = simUDID
            isPhysical = false
        case .physical(let device):
            let platform = DeviceHelper.xcodebuildPlatform(for: device)
            destination = "platform=\(platform),id=\(device.udid)"
            udid = device.udid
            isPhysical = true
        case .unknown:
            // Fall back to name-based destination (may work if Xcode resolves it)
            destination = "platform=\(platformForDevice(deviceName)),name=\(deviceName)"
            udid = ""
            isPhysical = false
        }

        let process = try launchXcodebuild(destination: destination, port: port, udid: udid)
        let pid = process.processIdentifier

        // For physical devices, connect using the device hostname from devicectl
        let host: String
        if isPhysical, case .physical(let device) = resolved {
            guard waitForHealth(host: device.hostname.urlHost, port: port) else {
                process.terminate()
                throw CLIError.commandFailed("Agent on physical device failed to start within 120 seconds")
            }
            host = device.hostname
        } else {
            guard waitForHealth(port: port) else {
                process.terminate()
                throw CLIError.commandFailed("Agent failed to start within 60 seconds")
            }
            host = "localhost"
        }

        AgentRegistry.add(AgentRecord(
            port: port, pid: pid, udid: udid,
            device: deviceName, isClone: false, startedAt: Date(),
            host: host, isPhysical: isPhysical
        ))

        let result: [String: Any] = [
            "success": true,
            "data": [
                "pid": Int(pid),
                "device": deviceName,
                "port": port,
                "host": host,
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
        let logPath = NSTemporaryDirectory() + "simpilot-xcodebuild-\(port).log"
        let logFile = FileManager.default.createFile(atPath: logPath, contents: nil)
        let logHandle = logFile ? FileHandle(forWritingAtPath: logPath) : nil
        process.standardOutput = logHandle ?? FileHandle.nullDevice
        process.standardError = logHandle ?? FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw CLIError.commandFailed("Failed to start xcodebuild: \(error.localizedDescription)")
        }

        return process
    }

    private static func waitForHealth(port: Int, timeout: TimeInterval = 60) -> Bool {
        waitForHealth(host: "localhost", port: port, timeout: timeout)
    }

    private static func waitForHealth(host: String, port: Int, timeout: TimeInterval = 120) -> Bool {
        let client = HTTPClient(host: host, port: port, timeout: 5)
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
        if let envDir = ProcessInfo.processInfo.environment["SIMPILOT_AGENT_DIR"] {
            let expanded = NSString(string: envDir).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded + "/AgentApp.xcodeproj") {
                return expanded
            }
        }
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
