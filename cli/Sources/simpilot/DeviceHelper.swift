import Foundation

enum DeviceHelper {

    struct PhysicalDevice {
        let udid: String
        let name: String
        let platform: String  // e.g. "iOS", "xrOS"
        let hostname: String  // e.g. "Yoshis-iPhone.coredevice.local"
    }

    /// Find a connected physical device by name using `xcrun devicectl`.
    static func findDevice(name: String) throws -> PhysicalDevice {
        let devices = try listDevices()
        guard let device = devices.first(where: { $0.name == name }) else {
            throw CLIError.commandFailed("Physical device not found: \(name). Is it connected?")
        }
        return device
    }

    /// List all connected physical devices.
    static func listDevices() throws -> [PhysicalDevice] {
        let tmpFile = NSTemporaryDirectory() + "simpilot-devicectl-\(ProcessInfo.processInfo.processIdentifier).json"
        defer { try? FileManager.default.removeItem(atPath: tmpFile) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["devicectl", "list", "devices", "--json-output", tmpFile]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw CLIError.commandFailed("Failed to run xcrun devicectl: \(error.localizedDescription)")
        }

        guard process.terminationStatus == 0 else {
            throw CLIError.commandFailed("xcrun devicectl exited with status \(process.terminationStatus)")
        }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: tmpFile)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let devices = result["devices"] as? [[String: Any]] else {
            throw CLIError.commandFailed("Failed to parse devicectl output")
        }

        return devices.compactMap { device in
            guard let identifier = device["identifier"] as? String,
                  let props = device["deviceProperties"] as? [String: Any],
                  let name = props["name"] as? String else {
                return nil
            }

            let platform: String
            if let osVersion = props["osVersionNumber"] as? String {
                if let platformStr = (device["hardwareProperties"] as? [String: Any])?["platform"] as? String {
                    switch platformStr {
                    case "xrOS": platform = "xrOS"
                    default: platform = "iOS"
                    }
                } else {
                    platform = osVersion.hasPrefix("2") ? "xrOS" : "iOS"
                }
            } else {
                platform = "iOS"
            }

            // Prefer stable mDNS hostname over ephemeral tunnelIPAddress (changes on each USB reconnect)
            let conn = device["connectionProperties"] as? [String: Any]
            let hostname: String
            if let hostnames = conn?["potentialHostnames"] as? [String], let first = hostnames.first {
                hostname = first
            } else if let tunnel = conn?["tunnelIPAddress"] as? String, !tunnel.isEmpty {
                hostname = tunnel
            } else {
                hostname = "\(identifier).coredevice.local"
            }

            return PhysicalDevice(udid: identifier, name: name, platform: platform, hostname: hostname)
        }
    }

    /// Returns the xcodebuild platform string for a physical device.
    static func xcodebuildPlatform(for device: PhysicalDevice) -> String {
        switch device.platform {
        case "xrOS": return "visionOS"
        default: return "iOS"
        }
    }
}
