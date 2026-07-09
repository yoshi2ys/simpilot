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
        var target = launchTarget(for: resolved)
        let token = TokenGenerator.make()
        let process = try launchXcodebuild(
            destination: target.destination,
            port: port,
            token: token,
            isPhysical: target.isPhysical
        )
        let pid = process.processIdentifier

        // For physical devices, connect using the device hostname from devicectl
        let host: String
        if target.isPhysical, case .physical(let device) = resolved {
            guard waitForHealth(host: device.hostname.urlHost, port: port, token: token) else {
                rollback(process: process, target: target)
                throw CLIError.commandFailed("Agent on physical device failed to start within 120 seconds")
            }
            host = device.hostname
        } else {
            guard waitForHealth(port: port, token: token) else {
                rollback(process: process, target: target)
                throw CLIError.commandFailed("Agent failed to start within 60 seconds")
            }
            host = loopbackHost
            // The `.unknown` destination launches by name, so we never learned a
            // UDID — and a record without one can't have its runner terminated
            // or its device deleted. The agent knows: it runs inside the
            // simulator and reports `SIMULATOR_UDID`. Ask it now, while it's up.
            if target.udid.isEmpty, let udid = simulatorUDID(port: port, token: token) {
                target = LaunchTarget(destination: target.destination, udid: udid, isPhysical: false)
            }
        }

        // An agent we cannot record is an agent nobody can `stop`.
        do {
            try AgentRegistry.add(AgentRecord(
                port: port, pid: pid, udid: target.udid,
                device: deviceName, isClone: false, startedAt: Date(),
                host: host, isPhysical: target.isPhysical,
                pidStartTime: ProcessIdentity.startTime(pid: pid), token: token
            ))
        } catch {
            rollback(process: process, target: target)
            throw error
        }

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
            let token = TokenGenerator.make()
            let process: Process
            do {
                process = try launchXcodebuild(
                    destination: target.destination,
                    port: port,
                    token: token,
                    isPhysical: false
                )
            } catch {
                SimctlHelper.deleteClone(udid: newUDID)
                throw error
            }

            let pid = process.processIdentifier

            guard waitForHealth(port: port, token: token) else {
                rollback(process: process, target: target, deleteClone: true)
                throw CLIError.commandFailed("Agent on port \(port) failed to start within 60 seconds")
            }

            do {
                try AgentRegistry.add(AgentRecord(
                    port: port, pid: pid, udid: newUDID,
                    device: newName, isClone: true, startedAt: Date(),
                    pidStartTime: ProcessIdentity.startTime(pid: pid), token: token
                ))
            } catch {
                rollback(process: process, target: target, deleteClone: true)
                throw error
            }

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

    /// Undo a launch that will not be registered.
    ///
    /// An agent is three things, not one: the `xcodebuild` process, the
    /// simulator-side `AgentUITests-Runner` it spawned (parented by
    /// `launchd_sim`, so it survives `xcodebuild` and keeps the port bound), and
    /// for `--clone`/`--create` the device itself. Terminating only the process
    /// — which every rollback here used to do — leaves the port held by a runner
    /// with no registry record, so the next `start` silently shifts to port+1.
    /// This mirrors `StopCommand.teardownAgent`.
    private static func rollback(process: Process, target: LaunchTarget, deleteClone: Bool = false) {
        process.terminate()
        guard !target.isPhysical, !target.udid.isEmpty else { return }
        SimctlHelper.terminateRunner(udid: target.udid)
        if deleteClone {
            SimctlHelper.deleteClone(udid: target.udid)
        }
    }

    /// Bind mode the agent must use to be reachable from this CLI. Simulators
    /// share the Mac's network stack, so loopback suffices and keeps the agent
    /// off the LAN; a physical device is reached over USB/Wi-Fi and has to
    /// listen on every interface (which the agent only permits with a token).
    static func bindMode(isPhysical: Bool) -> String {
        isPhysical ? "all" : "loopback"
    }

    /// The whole agent-configuration contract, in one testable place.
    ///
    /// `xcodebuild` strips the `TEST_RUNNER_` prefix and injects the rest into
    /// the XCUITest runner's environment, on simulators and physical devices
    /// alike, where `AgentConfig.resolve` reads them. The agent is a separate
    /// build target, so these key names and values cannot be a shared constant —
    /// they are pinned by `HTTPClientTokenTests` on this side and
    /// `AgentConfigTests` on the other.
    static func testRunnerEnvironment(port: Int, token: String, isPhysical: Bool) -> [String: String] {
        [
            "TEST_RUNNER_SIMPILOT_PORT": String(port),
            "TEST_RUNNER_SIMPILOT_TOKEN": token,
            "TEST_RUNNER_SIMPILOT_BIND": bindMode(isPhysical: isPhysical)
        ]
    }

    private static func launchXcodebuild(
        destination: String,
        port: Int,
        token: String,
        isPhysical: Bool
    ) throws -> Process {
        let projectDir = try findProjectDirectory()

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

        // Replaces the old `/tmp/simpilot-port-<UDID>` file, which only worked
        // because the simulator shares the host's `/tmp` and sat on a
        // predictable, squattable path.
        var env = ProcessInfo.processInfo.environment
        env.merge(testRunnerEnvironment(port: port, token: token, isPhysical: isPhysical)) { _, new in new }
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

    /// The agent binds `127.0.0.1` for simulators, so connect there directly
    /// rather than via `localhost` — that name resolves to `::1` first, and the
    /// IPv6 loopback is deliberately not bound.
    static let loopbackHost = "127.0.0.1"

    private static func waitForHealth(port: Int, token: String?, timeout: TimeInterval = 60) -> Bool {
        waitForHealth(host: loopbackHost, port: port, token: token, timeout: timeout)
    }

    private static func waitForHealth(host: String, port: Int, token: String?, timeout: TimeInterval = 120) -> Bool {
        let client = HTTPClient(host: host, port: port, timeout: 5, token: token)
        let startTime = Date()
        while Date().timeIntervalSince(startTime) < timeout {
            Thread.sleep(forTimeInterval: 1)
            if let data = try? client.get("/health"), isHealthyEnvelope(data) {
                return true
            }
        }
        return false
    }

    /// Ask a running simulator agent which device it is on. Nil when the reply
    /// is missing the field (a physical device, or a future agent that stopped
    /// reporting it) — callers must treat that as "UDID unknown", not as a
    /// failure to start.
    private static func simulatorUDID(port: Int, token: String?) -> String? {
        let client = HTTPClient(host: loopbackHost, port: port, timeout: 5, token: token)
        guard let data = try? client.get("/info"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = json["data"] as? [String: Any],
              let environment = payload["environment"] as? [String: Any],
              let udid = environment["SIMULATOR_UDID"] as? String,
              !udid.isEmpty else {
            return nil
        }
        return udid
    }

    /// A reply is only "healthy" if it is *our* agent answering.
    ///
    /// `HTTPClient` does not inspect HTTP status — non-2xx envelopes are a
    /// legitimate result everywhere else — so a bare "we got bytes back" check
    /// accepts a `401 unauthorized` from a *different* agent already squatting
    /// the port. `start` would then register the new token against the old
    /// agent's port and every later command would 401 forever.
    static func isHealthyEnvelope(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return json["success"] as? Bool == true
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
