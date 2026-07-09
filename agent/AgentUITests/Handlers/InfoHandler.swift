import Foundation

final class InfoHandler {
    /// The resolved config, not the raw environment. An agent launched straight
    /// from Xcode has no `SIMPILOT_PORT` set yet still listens on the default
    /// port, so reading the env would report nothing while the socket is open.
    /// `AgentConfig` stays the single reader of the env contract.
    private let config: AgentConfig

    init(config: AgentConfig) {
        self.config = config
    }

    func handle(_ request: HTTPRequest) -> Data {
        let processInfo = ProcessInfo.processInfo
        let isSimulator = processInfo.environment["SIMULATOR_UDID"] != nil

        var env: [String: Any] = [:]
        if isSimulator {
            if let v = processInfo.environment["SIMULATOR_DEVICE_NAME"] { env["SIMULATOR_DEVICE_NAME"] = v }
            if let v = processInfo.environment["SIMULATOR_RUNTIME_VERSION"] { env["SIMULATOR_RUNTIME_VERSION"] = v }
            if let v = processInfo.environment["SIMULATOR_UDID"] { env["SIMULATOR_UDID"] = v }
        }

        let info: [String: Any] = [
            "agent": "simpilot-xcuitest",
            "version": "1.0.0",
            "hostname": processInfo.hostName,
            "os": processInfo.operatingSystemVersionString,
            "processId": processInfo.processIdentifier,
            "isPhysicalDevice": !isSimulator,
            "port": Int(config.port),
            "bind": config.bind.rawValue,
            // Whether a token is required — never the token itself.
            "authenticated": config.token != nil,
            "environment": env
        ]

        return HTTPResponseBuilder.json(info)
    }
}
