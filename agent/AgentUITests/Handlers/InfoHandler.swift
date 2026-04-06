import Foundation

final class InfoHandler {
    func handle(_ request: HTTPRequest) -> Data {
        let processInfo = ProcessInfo.processInfo
        var env: [String: Any] = [:]
        if let v = processInfo.environment["SIMULATOR_DEVICE_NAME"] { env["SIMULATOR_DEVICE_NAME"] = v }
        if let v = processInfo.environment["SIMULATOR_RUNTIME_VERSION"] { env["SIMULATOR_RUNTIME_VERSION"] = v }
        if let v = processInfo.environment["SIMULATOR_UDID"] { env["SIMULATOR_UDID"] = v }
        if let v = processInfo.environment["SIMPILOT_PORT"] { env["SIMPILOT_PORT"] = v }

        let info: [String: Any] = [
            "agent": "simpilot-xcuitest",
            "version": "1.0.0",
            "hostname": processInfo.hostName,
            "os": processInfo.operatingSystemVersionString,
            "processId": processInfo.processIdentifier,
            "environment": env
        ]

        return HTTPResponseBuilder.json(info)
    }
}
