import Foundation

enum RotateCommand: SimpilotCommand {
    private static let kebabToCamel: [String: String] = [
        "portrait": "portrait",
        "portrait-upside-down": "portraitUpsideDown",
        "landscape-left": "landscapeLeft",
        "landscape-right": "landscapeRight",
    ]

    static let argSpec = ArgSpec(
        command: "rotate",
        positionals: [.init(name: "orientation", required: true)]
    )
    static let category: HelpCommands.Category = .interaction
    static let synopsis = "rotate <portrait|landscape-left|landscape-right|portrait-upside-down>"
    static let description = "Set device orientation"
    static let example = "simpilot rotate landscape-left"

    static func run(context: RunContext) throws {
        let parsed = try ArgParser.parse(context.args, spec: argSpec)
        let raw = parsed.positionals[0]

        guard let camel = kebabToCamel[raw.lowercased()] else {
            let valid = kebabToCamel.keys.sorted().joined(separator: ", ")
            throw CLIError.invalidArgs("Unsupported orientation: \(raw). Use: \(valid)")
        }

        let data = try context.client.post("/rotate", body: ["orientation": camel])
        try decodeAndPrint(data: data, pretty: context.pretty)
    }
}
