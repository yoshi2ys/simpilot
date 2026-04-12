import Foundation

// MARK: - Global Options

struct GlobalOptions {
    var port: Int = 8222
    /// True when `--port` was passed on the CLI (not the default, not env).
    /// Used by `stop` to decide whether to forward the global port as a target.
    /// Env `SIMPILOT_PORT` is intentionally NOT treated as explicit — it's ambient
    /// session default, not a per-invocation assertion.
    var portExplicit: Bool = false
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
    if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
       let str = String(data: data, encoding: .utf8) {
        print(str)
    }
}

func printResponse(data: Data, pretty: Bool) {
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

// MARK: - Entry Point

@main
struct Simpilot {
    /// Spec for global options. Used to strict-parse the leading flags before the
    /// subcommand name. Subcommand-local flags are parsed by the subcommand itself.
    static let globalArgSpec = ArgSpec(
        command: "simpilot",
        flags: [
            .init("--port", .int),
            .init("--pretty", .bool),
            .init("--timeout", .double),
            .init("--help", .bool),
        ]
    )

    /// The only list of commands. Help rendering, dispatch, and the drift
    /// backstop test all iterate this array. Adding a new command means
    /// adding exactly one entry here.
    static let registry: [any SimpilotCommand.Type] = [
        HealthCommand.self,
        ListCommand.self,
        InfoCommand.self,
        StartCommand.self,
        StopCommand.self,
        LaunchCommand.self,
        TerminateCommand.self,
        ActivateCommand.self,
        TapCommand.self,
        TapCoordCommand.self,
        TypeCommand.self,
        SwipeCommand.self,
        LongPressCommand.self,
        DoubleTapCommand.self,
        RotateCommand.self,
        OpenURLCommand.self,
        AlertCommand.self,
        WaitCommand.self,
        AssertCommand.self,
        ScrollToCommand.self,
        DragCommand.self,
        PinchCommand.self,
        ElementsCommand.self,
        ScreenshotCommand.self,
        SourceCommand.self,
        ClipboardCommand.self,
        AppearanceCommand.self,
        LocationCommand.self,
        BatchCommand.self,
        ActionCommand.self,
        RunCommand.self,
        HelpCommand.self,
    ]

    static func main() {
        let options: GlobalOptions
        do {
            options = try parseArguments()
        } catch let error as CLIError {
            handleCLIError(error)
        } catch {
            printError(code: "command_failed", message: error.localizedDescription)
            exit(2)
        }

        // Resolve host from agent registry (supports physical devices with non-localhost hosts).
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

        run(options: options, client: client)
    }

    static func parseArguments() throws -> GlobalOptions {
        try parseArguments(rawArgs: Array(CommandLine.arguments.dropFirst()))
    }

    /// Strict global-options parser.
    ///
    /// Splits `rawArgs` at the first non-flag token (the subcommand name). Tokens
    /// before the split are parsed against `globalArgSpec`; tokens after are passed
    /// verbatim to the subcommand. Unknown global flags surface as
    /// `CLIError.invalidArgs` (exit 3) instead of being silently coerced into a
    /// command name. The strict parse runs *before* the `--help` branch so that
    /// `simpilot --port nope --help` errors on `--port` rather than swallowing the
    /// preceding malformed flag.
    static func parseArguments(rawArgs: [String]) throws -> GlobalOptions {
        var options = GlobalOptions()

        if let envPort = ProcessInfo.processInfo.environment["SIMPILOT_PORT"],
           let p = Int(envPort) {
            options.port = p
        }

        let split = splitGlobalFromCommand(rawArgs)
        let commandTokens = split.command

        // Normalize the short alias `-h` to `--help` so the spec only models one
        // flag. ArgParser doesn't support short flags by design.
        let normalizedGlobalArgs = split.global.map { $0 == "-h" ? "--help" : $0 }

        let parsed = try ArgParser.parse(normalizedGlobalArgs, spec: globalArgSpec)

        if parsed.bool("--help") {
            options.command = "help"
            options.helpFormat = .text
            return options
        }

        if let p = parsed.int("--port") {
            options.port = p
            options.portExplicit = true
        }
        if parsed.bool("--pretty") {
            options.pretty = true
        }
        if let t = parsed.double("--timeout") {
            options.timeout = t
        }

        if commandTokens.isEmpty {
            options.command = "help"
            options.helpFormat = .text
            return options
        }

        options.command = commandTokens[0]
        options.commandArgs = Array(commandTokens.dropFirst())
        return options
    }

    /// Walk `args` and peel off the leading global-flag tokens (and their values),
    /// stopping at the first token that is not a known global flag. The remainder
    /// is the subcommand and its args. ArgParser then strictly validates the peeled
    /// prefix — unknown `--foo` is forwarded so `parse` rejects it with a helpful
    /// error rather than letting it masquerade as a subcommand name.
    private static func splitGlobalFromCommand(_ args: [String]) -> (global: [String], command: [String]) {
        let globalFlagNames = Set(globalArgSpec.flags.map { $0.name })
        let valueFlags: Set<String> = Set(globalArgSpec.flags.compactMap { flag -> String? in
            switch flag.kind {
            case .bool: return nil
            default: return flag.name
            }
        })

        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "-h" || arg == "--help" {
                i += 1
                continue
            }
            if globalFlagNames.contains(arg) {
                i += 1
                if valueFlags.contains(arg) && i < args.count {
                    i += 1
                }
                continue
            }
            if ArgParser.isFlagLike(arg) {
                return (Array(args[..<(i + 1)]), Array(args[(i + 1)...]))
            }
            return (Array(args[..<i]), Array(args[i...]))
        }
        return (args, [])
    }

    /// Fail-fast on structural invariants over `registry` before any dispatch.
    /// Currently enforces: no two commands share a `name` (else
    /// `registry.first(where:)` would silently shadow the later entry and
    /// `simpilot --help` would render a duplicate row). Cheap enough (one
    /// `Set` over ~23 strings) to run on every invocation; the alternative
    /// of a static-init wrapper adds two registry variables for no real win.
    static func assertRegistryInvariants() {
        let names = registry.map { $0.name }
        precondition(
            Set(names).count == names.count,
            "Simpilot.registry contains duplicate command names: \(names)"
        )
    }

    static func run(options: GlobalOptions, client: HTTPClient) {
        assertRegistryInvariants()
        guard let cmdType = registry.first(where: { $0.name == options.command }) else {
            printError(code: "invalid_args", message: "Unknown command: \(options.command)")
            exit(3)
        }
        let context = RunContext(
            client: client,
            args: options.commandArgs,
            pretty: options.pretty,
            port: options.port,
            portExplicit: options.portExplicit,
            helpFormat: options.helpFormat
        )
        do {
            try cmdType.run(context: context)
        } catch let error as CLIError {
            handleCLIError(error)
        } catch {
            printError(code: "command_failed", message: error.localizedDescription)
            exit(2)
        }
    }

    private static func handleCLIError(_ error: CLIError) -> Never {
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
    }
}
