import Foundation

/// CLI-only command (no agent-side handler). Uses `xcrun simctl openurl`
/// directly because the XCUITest agent runs inside a single app and cannot
/// open arbitrary URL schemes system-wide.
enum OpenURLCommand: SimpilotCommand {
    static let argSpec = ArgSpec(
        command: "openurl",
        positionals: [.init(name: "url", required: true)]
    )
    static let category: HelpCommands.Category = .interaction
    static let synopsis = "openurl <url>"
    static let description = "Open a URL / deep link in the simulator"
    static let example = "simpilot openurl 'myapp://deep/link'"

    static func run(context: RunContext) throws {
        let parsed = try ArgParser.parse(context.args, spec: argSpec)
        let url = parsed.positionals[0]

        let agents = AgentRegistry.load()
        let agent: AgentRecord
        if context.portExplicit {
            guard let match = agents.first(where: { $0.port == context.port }) else {
                throw CLIError.commandFailed("No agent found on port \(context.port)")
            }
            agent = match
        } else {
            guard let first = agents.first else {
                throw CLIError.commandFailed("No running agent found. Start one with `simpilot start`")
            }
            agent = first
        }

        if agent.isPhysical {
            throw CLIError.invalidArgs("openurl is simulator-only (device \(agent.device) is physical)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "openurl", agent.udid, url]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw CLIError.commandFailed("simctl openurl exited with status \(process.terminationStatus)")
        }

        let result: [String: Any] = ["url": url, "udid": agent.udid]
        let data = try JSONSerialization.data(withJSONObject: ["success": true, "data": result], options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write("\n".data(using: .utf8)!)
    }
}
