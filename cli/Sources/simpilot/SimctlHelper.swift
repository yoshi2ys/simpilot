import Foundation

enum SimctlHelper {

    // MARK: - Device Lookup

    static func findDeviceUDID(name: String) throws -> String {
        let (_, devices) = try findDevice(name: name)
        return devices.udid
    }

    struct DeviceInfo {
        let udid: String
        let deviceTypeIdentifier: String
    }

    static func findDevice(name: String) throws -> (runtime: String, device: DeviceInfo) {
        let match: (runtime: String, device: DeviceInfo)? = try findFirstDevice { _, device in
            guard let deviceName = device["name"] as? String, deviceName == name,
                  let udid = device["udid"] as? String,
                  let isAvailable = device["isAvailable"] as? Bool, isAvailable,
                  let deviceTypeIdentifier = device["deviceTypeIdentifier"] as? String else {
                return nil
            }
            return DeviceInfo(udid: udid, deviceTypeIdentifier: deviceTypeIdentifier)
        }
        guard let match else {
            throw CLIError.commandFailed("Device not found: \(name)")
        }
        return match
    }

    /// First available `Booted` simulator across all runtimes, or `nil` if none.
    /// Iteration order follows JSON dictionary order (Xcode typically groups
    /// by runtime then insertion order inside `simctl list`). Used by
    /// `simpilot start` to pick a default device when neither `--device` nor
    /// `SIMPILOT_DEFAULT_DEVICE` is set.
    static func firstBootedDevice() throws -> (udid: String, name: String)? {
        try findFirstDevice { _, device in
            guard let udid = bootedUDID(device), let name = device["name"] as? String else {
                return nil
            }
            return (udid: udid, name: name)
        }?.device
    }

    /// Every booted simulator's UDID. Used by `simpilot stop --all` to sweep
    /// agent runners the registry never knew about.
    static func bootedDeviceUDIDs() throws -> [String] {
        try findAllDevices { _, device in bootedUDID(device) }
    }

    /// The one definition of "this simulator is booted", shared by both lookups
    /// above so they cannot disagree.
    private static func bootedUDID(_ device: [String: Any]) -> String? {
        guard device["state"] as? String == "Booted" else { return nil }
        return device["udid"] as? String
    }

    /// Reverse-lookup a simulator UDID to its human-readable name. Returns
    /// `nil` when the UDID is not a known simulator (which may mean it's a
    /// physical device or simply stale). Used by `simpilot start --udid` to
    /// derive the device name recorded in the agent registry.
    static func deviceName(udid: String) throws -> String? {
        try findFirstDevice { _, device in
            guard let deviceUDID = device["udid"] as? String, deviceUDID == udid,
                  let name = device["name"] as? String else {
                return nil
            }
            return name
        }?.device
    }

    /// Iterate every simulator entry across every runtime and return the first
    /// one for which `predicate` produces a non-nil value, paired with the
    /// runtime key that contained it. Keeps the `simctl list devices --json`
    /// traversal in one place so new lookups don't grow a third nested `for`.
    private static func findFirstDevice<T>(
        where predicate: (_ runtime: String, _ device: [String: Any]) -> T?
    ) throws -> (runtime: String, device: T)? {
        let devicesByRuntime = try listDevicesByRuntime()
        for (runtime, devices) in devicesByRuntime {
            for device in devices {
                if let value = predicate(runtime, device) {
                    return (runtime, value)
                }
            }
        }
        return nil
    }

    /// `findFirstDevice`'s collect-them-all sibling, for lookups that need every
    /// match rather than the first.
    private static func findAllDevices<T>(
        where predicate: (_ runtime: String, _ device: [String: Any]) -> T?
    ) throws -> [T] {
        try listDevicesByRuntime().flatMap { runtime, devices in
            devices.compactMap { predicate(runtime, $0) }
        }
    }

    private static func listDevicesByRuntime() throws -> [String: [[String: Any]]] {
        let output = try run(["simctl", "list", "devices", "--json"])
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devicesByRuntime = json["devices"] as? [String: [[String: Any]]] else {
            throw CLIError.commandFailed("Failed to parse simctl device list")
        }
        return devicesByRuntime
    }

    // MARK: - Clone / Create / Boot / Shutdown / Delete

    /// Clone an existing simulator device (copies state). Source must be Shutdown.
    static func cloneDevice(sourceUDID: String, newName: String) throws -> String {
        let output = try run(["simctl", "clone", sourceUDID, newName])
        let udid = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !udid.isEmpty else {
            throw CLIError.commandFailed("simctl clone returned empty UDID")
        }
        return udid
    }

    /// Create a new clean simulator device with the given type and runtime.
    static func createDevice(newName: String, deviceType: String, runtime: String) throws -> String {
        let output = try run(["simctl", "create", newName, deviceType, runtime])
        let udid = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !udid.isEmpty else {
            throw CLIError.commandFailed("simctl create returned empty UDID")
        }
        return udid
    }

    static func bootDevice(udid: String) throws {
        _ = try run(["simctl", "boot", udid])
    }

    static func shutdownDevice(udid: String) {
        _ = try? run(["simctl", "shutdown", udid])
    }

    static func deleteDevice(udid: String) throws {
        _ = try run(["simctl", "delete", udid])
    }

    /// Shutdown and delete a created simulator device.
    /// Bundle identifier of the XCUITest runner app Xcode installs on the
    /// simulator: the UI-test target's bundle id with `.xctrunner` appended.
    ///
    /// The runner is what actually holds the agent's listening socket. It is
    /// parented by the simulator's `launchd_sim`, not by `xcodebuild`, so
    /// SIGTERMing `xcodebuild` alone leaves it running and holding the port.
    static let runnerBundleID = "dev.yoshi.simpilot.AgentUITests.xctrunner"

    /// Best-effort shutdown of the runner app on `udid`. `simctl terminate` exits
    /// non-zero when the app is not running and when the device is gone; no
    /// caller can act on either, so the result is dropped.
    static func terminateRunner(udid: String) {
        _ = try? run(["simctl", "terminate", udid, runnerBundleID])
    }

    /// Best-effort removal of the runner app from `udid`.
    ///
    /// `terminate` frees the port but leaves the app installed, and `launchd_sim`
    /// goes on relaunching it in the background for hours. Only `xcodebuild test`
    /// puts `XCTest.framework` on the runner's search path, so every one of those
    /// background launches aborts in dyld with `Library not loaded:
    /// @rpath/XCTest.framework/XCTest` — and macOS raises a "quit unexpectedly"
    /// dialog for each. `start` reinstalls the runner (it runs `xcodebuild test`,
    /// not `test-without-building`), so removing it here is not a cost.
    static func uninstallRunner(udid: String) {
        _ = try? run(["simctl", "uninstall", udid, runnerBundleID])
    }

    /// Whether the runner app is installed on `udid`.
    ///
    /// `simctl uninstall` exits 0 whether or not the app was there, so it cannot
    /// report what it removed; `simctl get_app_container` exits non-zero only
    /// when the app is absent.
    static func isRunnerInstalled(udid: String) -> Bool {
        (try? run(["simctl", "get_app_container", udid, runnerBundleID])) != nil
    }

    /// The simulator-side teardown a runner needs, as data. Kept separate from
    /// `teardownRunner` so the branching is unit-testable without shelling out.
    enum TeardownStep: Equatable {
        case terminateRunner
        case uninstallRunner
        case deleteClone
    }

    /// Physical devices are driven by `devicectl`, so no `simctl` step applies to
    /// them. Removal and deletion are mutually exclusive: a `--clone`/`--create`
    /// device is deleted outright, which takes the runner app with it, so
    /// uninstalling it first would be wasted work.
    static func teardownSteps(udid: String, isPhysical: Bool, isClone: Bool) -> [TeardownStep] {
        guard !isPhysical, !udid.isEmpty else { return [] }
        return [.terminateRunner, isClone ? .deleteClone : .uninstallRunner]
    }

    /// Tear down the simulator-side half of an agent. The single place that
    /// knows what "removing a runner" means, so `stop`, `start`'s rollback, and
    /// the orphan sweep cannot drift apart.
    static func teardownRunner(udid: String, isPhysical: Bool, isClone: Bool) {
        for step in teardownSteps(udid: udid, isPhysical: isPhysical, isClone: isClone) {
            switch step {
            case .terminateRunner: terminateRunner(udid: udid)
            case .uninstallRunner: uninstallRunner(udid: udid)
            case .deleteClone: deleteClone(udid: udid)
            }
        }
    }

    /// Remove leftover agent runners from every booted simulator except the ones
    /// already torn down. Scoped by bundle identifier, so unlike a `pgrep -f`
    /// sweep it cannot touch another project's test runner.
    ///
    /// Selecting on whether `simctl terminate` found something to kill would miss
    /// the very state this sweep exists to clean: a runner that `launchd_sim`
    /// keeps relaunching into an immediate dyld abort is dead almost all the
    /// time. Select on *installed* instead.
    ///
    /// Returns the UDIDs where a runner was actually removed.
    static func sweepOrphanRunners(excluding knownUDIDs: Set<String>) -> [String] {
        let booted = (try? bootedDeviceUDIDs()) ?? []
        let orphans = booted.filter { !knownUDIDs.contains($0) && isRunnerInstalled(udid: $0) }
        for udid in orphans {
            teardownRunner(udid: udid, isPhysical: false, isClone: false)
        }
        return orphans
    }

    static func deleteClone(udid: String) {
        shutdownDevice(udid: udid)
        try? deleteDevice(udid: udid)
    }

    // MARK: - Runner

    private static func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw CLIError.commandFailed("Failed to run xcrun \(arguments.joined(separator: " ")): \(error.localizedDescription)")
        }

        // Drain stdout *before* waiting: `simctl list devices --json` output
        // easily exceeds the ~64KB pipe buffer, and a child blocked writing to a
        // full pipe never exits — so `waitUntilExit()` first would deadlock.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw CLIError.commandFailed("xcrun \(arguments.joined(separator: " ")) exited with status \(process.terminationStatus)")
        }

        return String(data: data, encoding: .utf8) ?? ""
    }
}
