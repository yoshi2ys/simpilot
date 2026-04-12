import Foundation

enum StartCommand: SimpilotCommand {
    static let argSpec = ArgSpec(
        command: "start",
        flags: [
            .init("--device", .string),
            .init("--udid", .string),
            .init("--clone", .optionalInt(default: 1)),
            .init("--create", .optionalInt(default: 1)),
        ]
    )
    static let category: HelpCommands.Category = .agent
    static let synopsis = "start [--device <name> | --udid <udid>] [--clone|--create [N]]"
    static let description = "Build and start the XCUITest agent"
    static let example = "simpilot start --device 'iPhone Air'"

    /// Last-resort default when no flag, no env, and no booted simulator is
    /// available. Kept non-empty so CI jobs without `SIMPILOT_DEFAULT_DEVICE`
    /// still hit a deterministic device.
    static let fallbackDeviceName = "iPhone 17 Pro"

    enum MultiMode: Equatable {
        case clone(Int)
        case create(Int)
    }

    /// Which slot in the priority chain produced the resolved device. Surfaced
    /// in the start envelope (`data.resolved_via`) so callers can always tell
    /// which fallback actually fired; silent fallback is forbidden.
    enum ResolvedVia: String {
        case explicitUdid = "explicit_udid"
        case explicitDevice = "explicit_device"
        case env
        case booted
        case fallback
    }

    struct ResolvedStart: Equatable {
        let deviceName: String
        /// Populated only when the chain already knows a concrete simulator
        /// UDID (explicit `--udid` or `booted`). `nil` means fall back to the
        /// name-based sim/physical lookup in `run`.
        let simulatorUDID: String?
        let resolvedVia: ResolvedVia
        let multiMode: MultiMode?
    }

    /// Injection seam for the simctl lookups used inside `resolveStart`. Lets
    /// unit tests drive every branch of the priority chain without spawning
    /// `xcrun simctl` subprocesses.
    struct SimctlLookup: Sendable {
        let firstBooted: @Sendable () -> (udid: String, name: String)?
        let deviceName: @Sendable (String) -> String?

        static let live = SimctlLookup(
            firstBooted: { try? SimctlHelper.firstBootedDevice() },
            deviceName: { try? SimctlHelper.deviceName(udid: $0) }
        )

        /// Lookup that never finds anything — used by tests to exercise the
        /// `env` / `fallback` branches deterministically.
        static let empty = SimctlLookup(
            firstBooted: { nil },
            deviceName: { _ in nil }
        )
    }

    /// Pure parse+resolve step. Owns the full priority chain:
    /// `--udid` > `--device` > `SIMPILOT_DEFAULT_DEVICE` > first booted sim >
    /// hardcoded `iPhone 17 Pro`. All `--clone`/`--create` invariants live
    /// here too so tests can exercise rejection without booting xcodebuild.
    static func resolveStart(
        args: [String],
        env: [String: String],
        lookup: SimctlLookup
    ) throws -> ResolvedStart {
        let parsed = try ArgParser.parse(args, spec: argSpec)

        let cloneCount = parsed.int("--clone")
        let createCount = parsed.int("--create")
        if cloneCount != nil && createCount != nil {
            throw CLIError.invalidArgs("start: --clone and --create are mutually exclusive")
        }
        if let n = cloneCount, n <= 0 {
            throw CLIError.invalidArgs("start: --clone count must be a positive integer (got \(n))")
        }
        if let n = createCount, n <= 0 {
            throw CLIError.invalidArgs("start: --create count must be a positive integer (got \(n))")
        }
        let multiMode: MultiMode? = cloneCount.map(MultiMode.clone) ?? createCount.map(MultiMode.create)

        let explicitDevice = parsed.string("--device")
        let explicitUdid = parsed.string("--udid")

        if let udid = explicitUdid {
            guard let resolvedName = lookup.deviceName(udid) else {
                throw CLIError.invalidArgs(
                    "start: --udid '\(udid)' is not a known simulator. "
                    + "Physical device UDIDs are not supported — use --device <name>"
                )
            }
            if let name = explicitDevice, name != resolvedName {
                throw CLIError.invalidArgs(
                    "start: --udid '\(udid)' resolves to device '\(resolvedName)', "
                    + "which does not match --device '\(name)'"
                )
            }
            return ResolvedStart(
                deviceName: resolvedName,
                simulatorUDID: udid,
                resolvedVia: .explicitUdid,
                multiMode: multiMode
            )
        }

        if let name = explicitDevice {
            return ResolvedStart(
                deviceName: name,
                simulatorUDID: nil,
                resolvedVia: .explicitDevice,
                multiMode: multiMode
            )
        }

        if let envName = env["SIMPILOT_DEFAULT_DEVICE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !envName.isEmpty {
            return ResolvedStart(
                deviceName: envName,
                simulatorUDID: nil,
                resolvedVia: .env,
                multiMode: multiMode
            )
        }

        if let booted = lookup.firstBooted() {
            return ResolvedStart(
                deviceName: booted.name,
                simulatorUDID: booted.udid,
                resolvedVia: .booted,
                multiMode: multiMode
            )
        }

        return ResolvedStart(
            deviceName: fallbackDeviceName,
            simulatorUDID: nil,
            resolvedVia: .fallback,
            multiMode: multiMode
        )
    }

    static func run(context: RunContext) throws {
        let resolved = try resolveStart(
            args: context.args,
            env: ProcessInfo.processInfo.environment,
            lookup: .live
        )
        let pretty = context.pretty
        let port = context.port

        // Pre-resolved simulator UDID short-circuits the name-based sim/physical
        // lookup. Multi-mode skips the short-circuit because `runMulti` only
        // knows how to find source devices by name (`findDevice(name:)`).
        if resolved.multiMode == nil, let udid = resolved.simulatorUDID {
            try runSingle(
                deviceName: resolved.deviceName,
                port: port,
                resolved: .simulator(udid: udid),
                resolvedVia: resolved.resolvedVia,
                pretty: pretty
            )
            return
        }

        let resolvedDevice = resolveDevice(name: resolved.deviceName)

        switch resolved.multiMode {
        case .clone(let count):
            if case .physical = resolvedDevice {
                throw CLIError.invalidArgs("--clone and --create are not supported for physical devices")
            }
            try runMulti(
                deviceName: resolved.deviceName,
                count: count,
                useClone: true,
                resolvedVia: resolved.resolvedVia,
                pretty: pretty
            )
        case .create(let count):
            if case .physical = resolvedDevice {
                throw CLIError.invalidArgs("--clone and --create are not supported for physical devices")
            }
            try runMulti(
                deviceName: resolved.deviceName,
                count: count,
                useClone: false,
                resolvedVia: resolved.resolvedVia,
                pretty: pretty
            )
        case nil:
            try runSingle(
                deviceName: resolved.deviceName,
                port: port,
                resolved: resolvedDevice,
                resolvedVia: resolved.resolvedVia,
                pretty: pretty
            )
        }
    }

    enum ResolvedDevice {
        case simulator(udid: String)
        case physical(device: DeviceHelper.PhysicalDevice)
        case unknown(name: String)
    }

    struct LaunchTarget: Equatable {
        let destination: String
        let udid: String
        let isPhysical: Bool
    }

    /// Build the xcodebuild `-destination` argument + registry UDID tuple
    /// from a resolved device. Whenever a concrete simulator UDID is known,
    /// we launch with `id=<UDID>` so duplicate-named simulators can't be
    /// confused. Only `.unknown` falls back to `name=<name>`.
    static func launchTarget(for resolved: ResolvedDevice) -> LaunchTarget {
        switch resolved {
        case .simulator(let udid):
            return LaunchTarget(destination: "id=\(udid)", udid: udid, isPhysical: false)
        case .physical(let device):
            let platform = DeviceHelper.xcodebuildPlatform(for: device)
            return LaunchTarget(
                destination: "platform=\(platform),id=\(device.udid)",
                udid: device.udid,
                isPhysical: true
            )
        case .unknown(let name):
            return LaunchTarget(
                destination: "platform=\(platformForDevice(name)),name=\(name)",
                udid: "",
                isPhysical: false
            )
        }
    }

    private static func resolveDevice(name: String) -> ResolvedDevice {
        // Try simulator first (preserves existing behavior)
        if let udid = try? SimctlHelper.findDeviceUDID(name: name) {
            return .simulator(udid: udid)
        }
        // Try physical device
        if let device = try? DeviceHelper.findDevice(name: name) {
            return .physical(device: device)
        }
        return .unknown(name: name)
    }

    // MARK: - Single Agent

    private static func runSingle(
        deviceName: String,
        port: Int,
        resolved: ResolvedDevice,
        resolvedVia: ResolvedVia,
        pretty: Bool
    ) throws {
        let target = launchTarget(for: resolved)
        let process = try launchXcodebuild(destination: target.destination, port: port, udid: target.udid)
        let pid = process.processIdentifier

        // For physical devices, connect using the device hostname from devicectl
        let host: String
        if target.isPhysical, case .physical(let device) = resolved {
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
            port: port, pid: pid, udid: target.udid,
            device: deviceName, isClone: false, startedAt: Date(),
            host: host, isPhysical: target.isPhysical
        ))

        let result: [String: Any] = [
            "success": true,
            "data": [
                "pid": Int(pid),
                "device": deviceName,
                "port": port,
                "host": host,
                "resolved_via": resolvedVia.rawValue,
                "message": "Agent started successfully"
            ] as [String: Any],
            "error": NSNull()
        ]
        printJSON(result, pretty: pretty)
    }

    // MARK: - Multi Agent (clone or create)

    private static func runMulti(
        deviceName: String,
        count: Int,
        useClone: Bool,
        resolvedVia: ResolvedVia,
        pretty: Bool
    ) throws {
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

            let target = launchTarget(for: .simulator(udid: newUDID))
            let process: Process
            do {
                process = try launchXcodebuild(
                    destination: target.destination,
                    port: port,
                    udid: target.udid
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
                "resolved_via": resolvedVia.rawValue,
                "message": "\(started.count) agent(s) started"
            ] as [String: Any],
            "error": NSNull()
        ]
        printJSON(result, pretty: pretty)
    }

    // MARK: - Helpers

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
