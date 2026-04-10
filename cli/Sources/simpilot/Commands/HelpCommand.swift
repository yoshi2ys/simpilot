import Foundation

enum HelpCommand {
    static func run(client: HTTPClient, args: [String], pretty: Bool, format: HelpFormat = .json) throws {
        switch format {
        case .text:
            print(textHelp())
        case .json:
            do {
                let data = try client.get("/help")
                printResponse(data: data, pretty: pretty)
            } catch CLIError.agentUnreachable {
                printJSON(staticHelpJSON(), pretty: pretty)
            }
        }
    }

    private static func textHelp() -> String {
        return """
        simpilot — Control iOS Simulator and devices via XCUITest

        USAGE
            simpilot [global-options] <command> [args...] [command-options]

        GLOBAL OPTIONS
            --port <port>       Agent port (default: 8222)
            --timeout <secs>    HTTP request timeout (default: 30)
            --pretty            Pretty-print JSON output
            -h, --help          Show this help

        AGENT LIFECYCLE
            start [--device <name>]      Build and start the XCUITest agent
            stop [--port <p>] [--all]    Stop one or all running agents
            health                       Check if the agent is responding
            list                         List running agents
            info                         Show agent and device info

        APP LIFECYCLE
            launch <bundleId>            Launch an app
            terminate <bundleId>         Terminate an app
            activate <bundleId>          Bring app to foreground

        UI INTERACTION
            tap <query>                  Tap an element by label/query
            tapcoord <x> <y>             Tap at screen coordinates
            type <text> [--into <q>]     Type text (use --method paste for clipboard)
            swipe <direction>            Swipe up, down, left, or right
            wait <query> [--timeout <s>] Wait for element to appear (or --gone)

        OBSERVATION
            elements [--level 0|1|2|3]   List UI elements at given detail level
            screenshot [--file <path>]   Capture a screenshot
            source                       Dump raw UI hierarchy

        UTILITY
            clipboard get|set <text>     Read or write the device clipboard
            appearance [light|dark]      Get or set appearance mode
            location <lat> <lon>         Simulate GPS location
            batch <json>                 Run multiple commands in one request
            action <type> ...            Compound action with screenshot/elements
            help                         Show machine-readable JSON help

        QUERY SYNTAX
            'General'                    Bare label match (fastest, ~1s)
            'button:Login'               Typed match by element class
            '#identifier'                Match by accessibility identifier (slow)

        EXAMPLES
            simpilot start --device 'iPhone Air'
            simpilot launch com.apple.Preferences
            simpilot elements --level 1
            simpilot tap 'General'
            simpilot action tap 'About' --screenshot /tmp/s.png --level 0
            simpilot stop --all

        Run `simpilot help` for machine-readable JSON output.
        """
    }

    private static func staticHelpJSON() -> [String: Any] {
        return [
            "name": "simpilot",
            "version": "1.0.0",
            "description": "CLI tool for controlling iOS Simulator and devices via XCUITest",
            "commands": [
                ["name": "health", "method": "GET", "description": "Check if agent is running", "args": [] as [Any], "example": "simpilot health"],
                ["name": "launch", "method": "POST", "description": "Launch an app by bundle ID", "args": [["name": "bundleId", "required": true, "description": "App bundle identifier"]], "example": "simpilot launch com.apple.mobilesafari"],
                ["name": "terminate", "method": "POST", "description": "Terminate a running app", "args": [["name": "bundleId", "required": true, "description": "App bundle identifier"]], "example": "simpilot terminate com.apple.mobilesafari"],
                ["name": "activate", "method": "POST", "description": "Bring a running app to foreground without relaunching", "args": [["name": "bundleId", "required": true, "description": "App bundle identifier"]], "example": "simpilot activate com.apple.mobilesafari"],
                ["name": "tap", "method": "POST", "description": "Tap a UI element", "args": [["name": "query", "required": true, "description": "Element query"]], "example": "simpilot tap 'button:Login'"],
                ["name": "tapcoord", "method": "POST", "description": "Tap at screen coordinates", "args": [["name": "x", "required": true] as [String: Any], ["name": "y", "required": true] as [String: Any]], "example": "simpilot tapcoord 200 400"],
                ["name": "type", "method": "POST", "description": "Type text into focused element or specified element", "args": [["name": "text", "required": true, "description": "Text to type"], ["name": "--into", "required": false, "description": "Element query to type into"]], "example": "simpilot type 'hello@example.com' --into '#emailField'"],
                ["name": "swipe", "method": "POST", "description": "Swipe in a direction", "args": [["name": "direction", "required": true, "description": "up, down, left, right"]], "example": "simpilot swipe up"],
                ["name": "screenshot", "method": "GET", "description": "Take a screenshot", "args": [["name": "--file", "required": false, "description": "Save to file path instead of base64"]], "example": "simpilot screenshot --file /tmp/screen.png"],
                ["name": "elements", "method": "GET", "description": "Get UI element tree or actionable elements list", "args": [["name": "--actionable", "required": false, "description": "Return flat list of actionable elements only"]], "example": "simpilot elements --actionable"],
                ["name": "wait", "method": "POST", "description": "Wait for an element to appear or disappear", "args": [["name": "query", "required": true, "description": "Element query"], ["name": "--timeout", "required": false, "description": "Timeout in seconds"]], "example": "simpilot wait '#loadingDone' --timeout 15"],
                ["name": "source", "method": "GET", "description": "Get raw UI hierarchy", "args": [] as [Any], "example": "simpilot source"],
                ["name": "info", "method": "GET", "description": "Get agent and device info", "args": [] as [Any], "example": "simpilot info"]
            ] as [[String: Any]],
            "note": "Agent is not running. Start with: simpilot start"
        ] as [String: Any]
    }
}
