import Foundation

final class HelpHandler {
    func handle(_ request: HTTPRequest) -> Data {
        let commands = buildCommands()
        let querySyntax = buildQuerySyntax()

        let helpData: [String: Any] = [
            "name": "simpilot",
            "version": "1.0.0",
            "description": "CLI tool for controlling iOS Simulator and devices via XCUITest",
            "commands": commands,
            "query_syntax": querySyntax
        ]

        return HTTPResponseBuilder.json(helpData)
    }

    private func cmd(_ name: String, _ method: String, _ description: String, _ args: [[String: Any]], _ example: String) -> [String: Any] {
        return ["name": name, "method": method, "description": description, "args": args, "example": example]
    }

    private func arg(_ name: String, required: Bool, _ description: String = "") -> [String: Any] {
        var a: [String: Any] = ["name": name, "required": required]
        if !description.isEmpty { a["description"] = description }
        return a
    }

    private func buildCommands() -> [[String: Any]] {
        return [
            cmd("health", "GET", "Check if agent is running", [], "simpilot health"),
            cmd("launch", "POST", "Launch an app by bundle ID",
                [arg("bundleId", required: true, "App bundle identifier")],
                "simpilot launch com.apple.mobilesafari"),
            cmd("terminate", "POST", "Terminate a running app",
                [arg("bundleId", required: true, "App bundle identifier")],
                "simpilot terminate com.apple.mobilesafari"),
            cmd("activate", "POST", "Bring a running app to foreground without relaunching",
                [arg("bundleId", required: true, "App bundle identifier")],
                "simpilot activate com.apple.mobilesafari"),
            cmd("tap", "POST", "Tap a UI element",
                [arg("query", required: true, "Element query (e.g. #id, button:Label, text:Label)")],
                "simpilot tap 'button:Login'"),
            cmd("tapcoord", "POST", "Tap at screen coordinates",
                [arg("x", required: true), arg("y", required: true)],
                "simpilot tapcoord 200 400"),
            cmd("type", "POST", "Type text into focused element or specified element",
                [arg("text", required: true, "Text to type"),
                 arg("--into", required: false, "Element query to type into")],
                "simpilot type 'hello@example.com' --into '#emailField'"),
            cmd("swipe", "POST", "Swipe in a direction",
                [arg("direction", required: true, "up, down, left, right"),
                 arg("--on", required: false, "Element query to swipe on"),
                 arg("--velocity", required: false, "slow, default, fast")],
                "simpilot swipe up"),
            cmd("screenshot", "GET", "Take a screenshot",
                [arg("--file", required: false, "Save to file path instead of base64")],
                "simpilot screenshot --file /tmp/screen.png"),
            cmd("elements", "GET", "Get UI element tree or actionable elements list",
                [arg("--app", required: false, "Bundle ID of target app"),
                 arg("--depth", required: false, "Tree depth limit (default: 3)"),
                 arg("--level", required: false, "Progressive detail: 0=summary, 1=actionable, 2=compact, 3=tree"),
                 arg("--actionable", required: false, "Return flat list of actionable elements only"),
                 arg("--compact", required: false, "Return compact tree (collapsed single-child chains)")],
                "simpilot elements --level 1"),
            cmd("wait", "POST", "Wait for an element to appear or disappear",
                [arg("query", required: true, "Element query"),
                 arg("--timeout", required: false, "Timeout in seconds (default: 10)"),
                 arg("--gone", required: false, "Wait for element to disappear")],
                "simpilot wait '#loadingDone' --timeout 15"),
            cmd("source", "GET", "Get raw UI hierarchy (Xcode debugDescription format)",
                [arg("--app", required: false, "Bundle ID of target app")],
                "simpilot source"),
            cmd("info", "GET", "Get agent and device info", [], "simpilot info"),
            cmd("batch", "POST", "Execute multiple commands in a single request",
                [arg("commands", required: true, "Array of {method, path, params?, body?} objects"),
                 arg("stop_on_error", required: false, "Stop executing on first error (default: false)")],
                "simpilot batch '{\"commands\":[{\"method\":\"GET\",\"path\":\"/health\"}]}'"),
            cmd("action", "POST", "Perform action then optionally capture screenshot and elements",
                [arg("action", required: true, "Action type: tap, type, swipe, tapcoord"),
                 arg("query", required: false, "Element query for the action target"),
                 arg("--screenshot", required: false, "Save screenshot to file path after action"),
                 arg("--level", required: false, "Include elements at given level after action"),
                 arg("--settle", required: false, "Wait time in seconds after action (default: 1.0)")],
                "simpilot action tap 'button:Login' --level 1 --screenshot /tmp/after.png")
        ]
    }

    private func buildQuerySyntax() -> [String: Any] {
        let formats: [[String: String]] = [
            ["pattern": "#identifier", "description": "Find by accessibility identifier", "example": "#loginButton"],
            ["pattern": "button:Label", "description": "Find button by label", "example": "button:Submit"],
            ["pattern": "text:Label", "description": "Find static text by label", "example": "text:Welcome"],
            ["pattern": "textField:Label", "description": "Find text field by label", "example": "textField:Email"],
            ["pattern": "secureTextField:Label", "description": "Find secure text field", "example": "secureTextField:Password"],
            ["pattern": "switch:Label", "description": "Find switch by label", "example": "switch:Dark Mode"],
            ["pattern": "cell:N", "description": "Find cell by index", "example": "cell:0"],
            ["pattern": "image:Label", "description": "Find image by label", "example": "image:Logo"],
            ["pattern": "nav:Title", "description": "Find navigation bar", "example": "nav:Settings"],
            ["pattern": "tab:Label", "description": "Find tab bar button", "example": "tab:Home"],
            ["pattern": "alert:Title", "description": "Find alert", "example": "alert:Error"],
            ["pattern": "link:Label", "description": "Find link by label", "example": "link:Learn more"],
            ["pattern": "Label", "description": "Search all elements by label or identifier", "example": "Login"]
        ]
        return [
            "description": "Element query format for tap, type, wait commands",
            "formats": formats
        ]
    }
}
