import Foundation

enum HelpCommand {
    static func run(client: HTTPClient, args: [String], pretty: Bool, format: HelpFormat = .json) throws {
        switch format {
        case .text:
            print(renderText())
        case .json:
            printJSON(renderJSON(), pretty: pretty)
        }
    }

    // MARK: - Text rendering

    private static func renderText() -> String {
        var lines: [String] = [
            "simpilot — \(HelpCommands.tagline)",
            "",
            "USAGE",
            "    simpilot [global-options] <command> [args...] [command-options]",
            "",
            "GLOBAL OPTIONS",
            "    --port <port>       Agent port (default: 8222)",
            "    --timeout <secs>    HTTP request timeout (default: 30)",
            "    --pretty            Pretty-print JSON output",
            "    -h, --help          Show this help",
            "",
        ]

        for category in HelpCommands.Category.allCases {
            let commands = HelpCommands.all.filter { $0.category == category }
            guard !commands.isEmpty else { continue }
            lines.append(category.rawValue)
            for cmd in commands {
                let synopsis = cmd.synopsis.padding(toLength: 56, withPad: " ", startingAt: 0)
                lines.append("    \(synopsis) \(cmd.description)")
            }
            lines.append("")
        }

        lines.append("QUERY SYNTAX")
        lines.append("    Used by tap, type --into, wait, and action commands.")
        lines.append("")
        for fmt in HelpCommands.queryFormats {
            let pattern = fmt.pattern.padding(toLength: 24, withPad: " ", startingAt: 0)
            lines.append("    \(pattern) \(fmt.description) (e.g. \(fmt.example))")
        }
        lines.append("")

        lines.append("EXAMPLES")
        let exampleNames = ["start", "launch", "elements", "tap", "action", "stop"]
        for name in exampleNames {
            if let cmd = HelpCommands.all.first(where: { $0.name == name }) {
                lines.append("    \(cmd.example)")
            }
        }
        lines.append("")
        lines.append("Run `simpilot help` for machine-readable JSON output.")

        return lines.joined(separator: "\n")
    }

    // MARK: - JSON rendering

    private static func renderJSON() -> [String: Any] {
        let commands: [[String: Any]] = HelpCommands.all.map { cmd in
            [
                "name": cmd.name,
                "category": cmd.category.rawValue,
                "synopsis": cmd.synopsis,
                "description": cmd.description,
                "example": cmd.example
            ]
        }
        let queryFormats: [[String: String]] = HelpCommands.queryFormats.map { fmt in
            [
                "pattern": fmt.pattern,
                "description": fmt.description,
                "example": fmt.example
            ]
        }
        return [
            "name": "simpilot",
            "version": HelpCommands.version,
            "description": HelpCommands.tagline,
            "commands": commands,
            "query_syntax": [
                "description": "Element query format for tap, type, wait, and action commands",
                "formats": queryFormats
            ]
        ]
    }
}
