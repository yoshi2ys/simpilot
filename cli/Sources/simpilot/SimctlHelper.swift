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
            guard let state = device["state"] as? String, state == "Booted",
                  let name = device["name"] as? String,
                  let udid = device["udid"] as? String else {
                return nil
            }
            return (udid: udid, name: name)
        }?.device
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
            process.waitUntilExit()
        } catch {
            throw CLIError.commandFailed("Failed to run xcrun \(arguments.joined(separator: " ")): \(error.localizedDescription)")
        }

        guard process.terminationStatus == 0 else {
            throw CLIError.commandFailed("xcrun \(arguments.joined(separator: " ")) exited with status \(process.terminationStatus)")
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
