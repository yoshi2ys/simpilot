import Foundation

/// Derives user-facing command documentation from the `Simpilot.registry`
/// so there is no hand-maintained list that can drift from the live dispatch
/// table. Used by `HelpCommand` to render both text and JSON output.
enum HelpCommands {
    enum Category: String, CaseIterable {
        case agent = "AGENT LIFECYCLE"
        case app = "APP LIFECYCLE"
        case interaction = "UI INTERACTION"
        case observation = "OBSERVATION"
        case utility = "UTILITY"
    }

    struct CommandInfo {
        let name: String
        let category: Category
        let synopsis: String
        let description: String
        let example: String
    }

    struct QueryFormat {
        let pattern: String
        let description: String
        let example: String
    }

    static let version = "1.0.0"
    static let tagline = "CLI tool for controlling iOS Simulator and devices via XCUITest"

    /// Derived once from `Simpilot.registry` — every subcommand type exposes
    /// its own metadata, so adding a command means editing exactly one place
    /// (the registry array in `Simpilot.swift`).
    static let all: [CommandInfo] = Simpilot.registry.map { cmd in
        CommandInfo(
            name: cmd.name,
            category: cmd.category,
            synopsis: cmd.synopsis,
            description: cmd.description,
            example: cmd.example
        )
    }

    static let queryFormats: [QueryFormat] = [
        .init(pattern: "Label",                 description: "Bare label match (fastest, ~1s)",           example: "'General'"),
        .init(pattern: "button:Label",          description: "Find button by label",                      example: "'button:Login'"),
        .init(pattern: "text:Label",            description: "Find static text by label",                 example: "'text:Welcome'"),
        .init(pattern: "textField:Label",       description: "Find text field by label",                  example: "'textField:Email'"),
        .init(pattern: "secureTextField:Label", description: "Find secure text field by label",           example: "'secureTextField:Password'"),
        .init(pattern: "searchField:Label",     description: "Find search field by label",                example: "'searchField:Search'"),
        .init(pattern: "switch:Label",          description: "Find switch by label",                      example: "'switch:Dark Mode'"),
        .init(pattern: "cell:N",                description: "Find cell by index",                        example: "'cell:0'"),
        .init(pattern: "image:Label",           description: "Find image by label",                       example: "'image:Logo'"),
        .init(pattern: "nav:Title",             description: "Find navigation bar",                       example: "'nav:Settings'"),
        .init(pattern: "tab:Label",             description: "Find tab bar button",                       example: "'tab:Home'"),
        .init(pattern: "alert:Title",           description: "Find alert",                                example: "'alert:Error'"),
        .init(pattern: "link:Label",            description: "Find link by label",                        example: "'link:Learn more'"),
        .init(pattern: "#identifier",           description: "Match by accessibility identifier (slow)",  example: "'#loginButton'"),
    ]
}
