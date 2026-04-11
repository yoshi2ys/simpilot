import Foundation

// MARK: - Argument Parsing

struct GlobalOptions {
    var port: Int = 8222
    var pretty: Bool = false
    var timeout: TimeInterval = 30
    var command: String = ""
    var commandArgs: [String] = []
    var helpFormat: HelpFormat = .json
}

enum HelpFormat {
    case json
    case text
}

func parseArguments() -> GlobalOptions {
    var options = GlobalOptions()

    // Default port from environment
    if let envPort = ProcessInfo.processInfo.environment["SIMPILOT_PORT"],
       let p = Int(envPort) {
        options.port = p
    }

    let rawArgs = Array(CommandLine.arguments.dropFirst()) // drop binary path
    var remaining: [String] = []
    var i = 0
    var foundCommand = false

    while i < rawArgs.count {
        let arg = rawArgs[i]

        // Once we hit the command name, stop consuming global flags.
        // This lets subcommands own their own --timeout, --device, etc.
        if foundCommand {
            remaining.append(arg)
            i += 1
            continue
        }

        switch arg {
        case "--port":
            i += 1
            guard i < rawArgs.count, let p = Int(rawArgs[i]) else {
                printError(code: "invalid_args", message: "Usage: --port <port>")
                exit(3)
            }
            options.port = p
        case "--pretty":
            options.pretty = true
        case "--timeout":
            i += 1
            guard i < rawArgs.count, let t = Double(rawArgs[i]) else {
                printError(code: "invalid_args", message: "Usage: --timeout <seconds>")
                exit(3)
            }
            options.timeout = t
        case "-h", "--help":
            options.command = "help"
            options.helpFormat = .text
            return options
        default:
            remaining.append(arg)
            foundCommand = true
        }
        i += 1
    }

    if remaining.isEmpty {
        options.command = "help"
        options.helpFormat = .text
        return options
    }

    options.command = remaining[0]
    options.commandArgs = Array(remaining.dropFirst())
    return options
}

// MARK: - Output Helpers

func printJSON(_ object: Any, pretty: Bool) {
    let opts: JSONSerialization.WritingOptions = pretty
        ? [.prettyPrinted, .sortedKeys]
        : [.sortedKeys]
    if let data = try? JSONSerialization.data(withJSONObject: object, options: opts),
       let str = String(data: data, encoding: .utf8) {
        print(str)
    }
}

func printError(code: String, message: String) {
    let obj: [String: Any] = [
        "success": false,
        "data": NSNull(),
        "error": ["code": code, "message": message]
    ]
    // Always pretty-print errors for readability on stderr-like scenarios,
    // but respect the global pretty flag if available
    if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
       let str = String(data: data, encoding: .utf8) {
        print(str)
    }
}

func printResponse(data: Data, pretty: Bool) {
    // Try to parse as JSON and re-serialize with pretty option
    if let json = try? JSONSerialization.jsonObject(with: data) {
        printJSON(json, pretty: pretty)
    } else if let str = String(data: data, encoding: .utf8) {
        print(str)
    }
}

/// Prints the agent response, then throws `CLIError.commandFailed` when the envelope
/// reports `success: false`. Callers that want agent-reported failures to surface as
/// exit code 2 must use this instead of `printResponse`.
func decodeAndPrint(data: Data, pretty: Bool) throws {
    // Parse once, print, then inspect `success`. Falling back to the raw string path
    // mirrors `printResponse` so non-JSON payloads still surface to the user.
    guard let json = try? JSONSerialization.jsonObject(with: data) else {
        if let str = String(data: data, encoding: .utf8) {
            print(str)
        }
        return
    }
    printJSON(json, pretty: pretty)

    guard let dict = json as? [String: Any],
          (dict["success"] as? Bool) == false else {
        return
    }
    let error = dict["error"] as? [String: Any]
    let code = error?["code"] as? String
    let message = (error?["message"] as? String)
        ?? code
        ?? "agent returned success:false"
    // invalid_regex surfaces as exit 3 (invalid args) to match the CLI-side
    // preflight path. Other agent-reported failures keep the exit-2 mapping.
    if code == "invalid_regex" {
        throw CLIError.invalidArgs(message)
    }
    throw CLIError.commandFailed(message)
}

// MARK: - Main

let options = parseArguments()

// Resolve host from agent registry (supports physical devices with non-localhost hosts)
let resolvedHost: String = {
    if let record = AgentRegistry.load().first(where: { $0.port == options.port }) {
        return record.host
    }
    return "localhost"
}()

let client = HTTPClient(
    host: resolvedHost,
    port: options.port,
    timeout: options.timeout
)

func run() {
    do {
        switch options.command {
        case "help":
            try HelpCommand.run(client: client, args: options.commandArgs, pretty: options.pretty, format: options.helpFormat)
        case "health":
            try HealthCommand.run(client: client, args: options.commandArgs, pretty: options.pretty)
        case "launch":
            try LaunchCommand.run(client: client, args: options.commandArgs, pretty: options.pretty)
        case "terminate":
            try TerminateCommand.run(client: client, args: options.commandArgs, pretty: options.pretty)
        case "activate":
            try ActivateCommand.run(client: client, args: options.commandArgs, pretty: options.pretty)
        case "tap":
            try TapCommand.run(client: client, args: options.commandArgs, pretty: options.pretty)
        case "tapcoord":
            try TapCoordCommand.run(client: client, args: options.commandArgs, pretty: options.pretty)
        case "type":
            try TypeCommand.run(client: client, args: options.commandArgs, pretty: options.pretty)
        case "swipe":
            try SwipeCommand.run(client: client, args: options.commandArgs, pretty: options.pretty)
        case "screenshot":
            try ScreenshotCommand.run(client: client, args: options.commandArgs, pretty: options.pretty)
        case "elements":
            try ElementsCommand.run(client: client, args: options.commandArgs, pretty: options.pretty)
        case "wait":
            try WaitCommand.run(client: client, args: options.commandArgs, pretty: options.pretty)
        case "assert":
            try AssertCommand.run(client: client, args: options.commandArgs, pretty: options.pretty)
        case "source":
            try SourceCommand.run(client: client, args: options.commandArgs, pretty: options.pretty)
        case "info":
            try InfoCommand.run(client: client, args: options.commandArgs, pretty: options.pretty)
        case "batch":
            try BatchCommand.run(client: client, args: options.commandArgs, pretty: options.pretty)
        case "action":
            try ActionCommand.run(client: client, args: options.commandArgs, pretty: options.pretty)
        case "clipboard":
            try ClipboardCommand.run(client: client, args: options.commandArgs, pretty: options.pretty)
        case "appearance":
            try AppearanceCommand.run(client: client, args: options.commandArgs, pretty: options.pretty)
        case "location":
            try LocationCommand.run(client: client, args: options.commandArgs, pretty: options.pretty)
        case "start":
            try StartCommand.run(args: options.commandArgs, pretty: options.pretty, port: options.port)
        case "stop":
            try StopCommand.run(args: options.commandArgs, pretty: options.pretty, port: options.port)
        case "list":
            try ListCommand.run(args: options.commandArgs, pretty: options.pretty)
        default:
            printError(code: "invalid_args", message: "Unknown command: \(options.command)")
            exit(3)
        }
    } catch let error as CLIError {
        switch error {
        case .agentUnreachable(let url):
            printError(code: "agent_unreachable", message: "Cannot connect to agent at \(url)")
            exit(1)
        case .invalidArgs(let msg):
            printError(code: "invalid_args", message: msg)
            exit(3)
        case .commandFailed(let msg):
            printError(code: "command_failed", message: msg)
            exit(2)
        case .invalidURL(let url):
            printError(code: "invalid_args", message: "Invalid URL: \(url)")
            exit(3)
        }
    } catch {
        printError(code: "command_failed", message: error.localizedDescription)
        exit(2)
    }
}

run()
