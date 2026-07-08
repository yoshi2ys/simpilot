import Foundation

enum ButtonCommand: SimpilotCommand {
    static let argSpec = ArgSpec(
        command: "button",
        positionals: [.init(name: "name", required: true)]
    )
    static let category: HelpCommands.Category = .interaction
    static let synopsis = "button <home|volume-up|volume-down|menu|play-pause|select|up|down|left|right>"
    static let description = "Press a hardware button (iOS: home/volume) or tvOS remote button"
    static let example = "simpilot button home"

    static func run(context: RunContext) throws {
        let parsed = try ArgParser.parse(context.args, spec: argSpec)
        // Accept kebab-case like the rest of the CLI (`rotate landscape-left`)
        // and forward the agent's camelCase wire name. The valid set is
        // platform-specific, so the agent — not the CLI — validates it and
        // returns `invalid_args`/`unsupported_platform` for a name this device
        // can't press.
        let name = kebabToCamel(parsed.positionals[0].lowercased())
        let data = try context.client.post("/button", body: ["name": name])
        try decodeAndPrint(data: data, pretty: context.pretty)
    }

    /// `volume-up` -> `volumeUp`; a token with no hyphen (`home`, `menu`) is
    /// returned unchanged.
    static func kebabToCamel(_ token: String) -> String {
        let parts = token.split(separator: "-").map(String.init)
        guard parts.count > 1 else { return token }
        return parts[0] + parts[1...].map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }
}
