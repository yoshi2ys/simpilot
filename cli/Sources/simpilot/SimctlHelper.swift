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
        let output = try run(["simctl", "list", "devices", "--json"])
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devicesByRuntime = json["devices"] as? [String: [[String: Any]]] else {
            throw CLIError.commandFailed("Failed to parse simctl device list")
        }

        for (runtime, devices) in devicesByRuntime {
            for device in devices {
                if let deviceName = device["name"] as? String,
                   let udid = device["udid"] as? String,
                   deviceName == name,
                   let isAvailable = device["isAvailable"] as? Bool,
                   isAvailable,
                   let deviceTypeIdentifier = device["deviceTypeIdentifier"] as? String {
                    let info = DeviceInfo(
                        udid: udid,
                        deviceTypeIdentifier: deviceTypeIdentifier
                    )
                    return (runtime, info)
                }
            }
        }

        throw CLIError.commandFailed("Device not found: \(name)")
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
