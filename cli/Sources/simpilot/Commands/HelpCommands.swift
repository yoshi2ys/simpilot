import Foundation

/// Single source of truth for user-facing command documentation.
/// Used by HelpCommand to render both human text and JSON help output.
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

    static let all: [CommandInfo] = [
        // AGENT LIFECYCLE
        .init(name: "start", category: .agent,
              synopsis: "start [--device <name>] [--clone|--create [N]]",
              description: "Build and start the XCUITest agent",
              example: "simpilot start --device 'iPhone Air'"),
        .init(name: "stop", category: .agent,
              synopsis: "stop [--port <p>] [--all]",
              description: "Stop one or all running agents",
              example: "simpilot stop --all"),
        .init(name: "health", category: .agent,
              synopsis: "health",
              description: "Check if the agent is responding",
              example: "simpilot health"),
        .init(name: "list", category: .agent,
              synopsis: "list",
              description: "List running agents",
              example: "simpilot list"),
        .init(name: "info", category: .agent,
              synopsis: "info",
              description: "Show agent and device info",
              example: "simpilot info"),

        // APP LIFECYCLE
        .init(name: "launch", category: .app,
              synopsis: "launch <bundleId>",
              description: "Launch an app by bundle ID",
              example: "simpilot launch com.apple.Preferences"),
        .init(name: "terminate", category: .app,
              synopsis: "terminate <bundleId>",
              description: "Terminate a running app",
              example: "simpilot terminate com.apple.Preferences"),
        .init(name: "activate", category: .app,
              synopsis: "activate <bundleId>",
              description: "Bring a running app to the foreground",
              example: "simpilot activate com.apple.Preferences"),

        // UI INTERACTION
        .init(name: "tap", category: .interaction,
              synopsis: "tap <query>",
              description: "Tap an element by label/query",
              example: "simpilot tap 'General'"),
        .init(name: "tapcoord", category: .interaction,
              synopsis: "tapcoord <x> <y>",
              description: "Tap at screen coordinates",
              example: "simpilot tapcoord 200 400"),
        .init(name: "type", category: .interaction,
              synopsis: "type <text> [--into <query>] [--method type|paste|auto]",
              description: "Type text into focused or specified element",
              example: "simpilot type 'hello' --into 'textField:Email'"),
        .init(name: "swipe", category: .interaction,
              synopsis: "swipe <up|down|left|right> [--on <query>]",
              description: "Swipe in a direction",
              example: "simpilot swipe up"),
        .init(name: "wait", category: .interaction,
              synopsis: "wait <query> [--timeout <s>] [--gone]",
              description: "Wait for element to appear or disappear",
              example: "simpilot wait 'General' --timeout 10"),

        // OBSERVATION
        .init(name: "elements", category: .observation,
              synopsis: "elements [--level 0|1|2|3]",
              description: "List UI elements at given detail level",
              example: "simpilot elements --level 1"),
        .init(name: "screenshot", category: .observation,
              synopsis: "screenshot [--file <path>]",
              description: "Capture a screenshot",
              example: "simpilot screenshot --file /tmp/s.png"),
        .init(name: "source", category: .observation,
              synopsis: "source",
              description: "Dump raw UI hierarchy (debugDescription)",
              example: "simpilot source"),

        // UTILITY
        .init(name: "clipboard", category: .utility,
              synopsis: "clipboard get | clipboard set <text>",
              description: "Read or write the device clipboard",
              example: "simpilot clipboard set 'hello'"),
        .init(name: "appearance", category: .utility,
              synopsis: "appearance [light|dark]",
              description: "Get or set appearance mode",
              example: "simpilot appearance dark"),
        .init(name: "location", category: .utility,
              synopsis: "location <lat> <lon>",
              description: "Simulate GPS location (iOS 17+)",
              example: "simpilot location 35.6812 139.7671"),
        .init(name: "batch", category: .utility,
              synopsis: "batch <json>",
              description: "Run multiple commands in one request",
              example: #"simpilot batch '{"commands":[{"method":"GET","path":"/health"}]}'"#),
        .init(name: "action", category: .utility,
              synopsis: "action <type> <query> [--screenshot <path>] [--level N] [--settle <s>]",
              description: "Compound action with screenshot/elements",
              example: "simpilot action tap 'About' --screenshot /tmp/s.png --level 0"),
        .init(name: "help", category: .utility,
              synopsis: "help",
              description: "Show machine-readable JSON help",
              example: "simpilot help"),
    ]

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
