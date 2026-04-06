import Foundation

enum HelpCommand {
    static func run(client: HTTPClient, args: [String], pretty: Bool) throws {
        do {
            let data = try client.get("/help")
            printResponse(data: data, pretty: pretty)
        } catch CLIError.agentUnreachable {
            // Fallback: print static help when agent is not running
            let fallback = staticHelpJSON()
            printJSON(fallback, pretty: pretty)
        }
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
