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

/// A command has already written everything it intends to write, and only its
/// exit status is left to deliver. `main` exits with `status` and prints nothing
/// more.
///
/// Deliberately not a `CLIError` case. Swift's exhaustiveness check is
/// per-type, not per-reachable-path, so a new case would force a branch in
/// every `switch` over `CLIError` — `Simpilot.envelope` and `ScenarioRunner`
/// alike — and each would have to invent a `(code, message)` for a value whose
/// whole point is that it has none.
///
/// Only `Simpilot.run` knows what to do with it, so throw it only from a path
/// that unwinds straight there: `decodeAndPrint`, or a command's own tail. A
/// scenario step must never throw it — `ScenarioRunner`'s generic `catch` would
/// swallow the status and report the default `localizedDescription`.
struct AlreadyReported: Error {
    let status: Int32
}

/// The exit status implied by a decoded agent envelope, or `nil` when the agent
/// reported success. `invalid_regex` surfaces as exit 3 (invalid args) to match
/// the CLI-side preflight path; other agent-reported failures keep the exit-2
/// mapping.
func agentFailureStatus(in json: Any) -> Int32? {
    guard let dict = json as? [String: Any],
          (dict["success"] as? Bool) == false else {
        return nil
    }
    let code = (dict["error"] as? [String: Any])?["code"] as? String
    return code == "invalid_regex" ? 3 : 2
}

/// Prints the agent's envelope — the *only* thing this command writes to stdout —
/// then throws `AlreadyReported` when it reports `success: false`.
///
/// The agent's envelope is the response. Throwing a `CLIError` here instead would
/// make `main` print a second envelope, so `stdout` would hold two JSON objects
/// (`json.loads` fails on the pair) and the specific code the agent chose
/// (`element_not_found`) would be buried under a generic `command_failed`.
func decodeAndPrint(data: Data, pretty: Bool) throws {
    guard let json = try? JSONSerialization.jsonObject(with: data) else {
        if let str = String(data: data, encoding: .utf8) {
            print(str)
        }
        return
    }
    printJSON(json, pretty: pretty)

    if let status = agentFailureStatus(in: json) {
        throw AlreadyReported(status: status)
    }
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
        ButtonCommand.self,
        OpenURLCommand.self,
        AlertCommand.self,
        WaitCommand.self,
        AssertCommand.self,
        ScrollToCommand.self,
        DragCommand.self,
        PinchCommand.self,
        SliderCommand.self,
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

        // Resolve host and token from the agent registry. Physical devices sit on
        // a non-loopback host; every agent the CLI starts requires its token.
        //
        // A corrupt registry must not be fatal *here*: `stop --all` is the tool
        // you reach for when things are broken, and it needs no registry to
        // sweep orphans. Warn on stderr and carry on token-less; commands that
        // genuinely need the registry (`list`, `stop --port`) load it themselves
        // and fail with the specific message.
        var record: AgentRecord?
        do {
            record = try AgentRegistry.load().first { $0.port == options.port }
        } catch {
            FileHandle.standardError.write(Data("simpilot: \(error)\n".utf8))
            record = nil
        }

        let client = HTTPClient(
            host: record?.host ?? StartCommand.loopbackHost,
            port: options.port,
            timeout: options.timeout,
            token: record?.token
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
        } catch let reported as AlreadyReported {
            // stdout already carries the command's own output. Printing an error
            // envelope on top of it would leave stdout unparseable.
            exit(reported.status)
        } catch let error as CLIError {
            handleCLIError(error)
        } catch {
            printError(code: "command_failed", message: error.localizedDescription)
            exit(2)
        }
    }

    /// The error envelope and exit status for a `CLIError`. Pure, so the
    /// mapping can be tested — `handleCLIError` itself calls `exit(_:)` and
    /// cannot be. `agent_timeout` (4) must stay distinct from
    /// `agent_unreachable` (1): the first means "retry with a longer budget",
    /// the second means "there is no agent there".
    static func envelope(for error: CLIError) -> (code: String, message: String, status: Int32) {
        switch error {
        case .agentUnreachable(let url):
            return ("agent_unreachable", "Cannot connect to agent at \(url)", 1)
        case .agentTimeout(let url, let seconds):
            return ("agent_timeout", "Agent at \(url) did not respond within \(Int(seconds))s", 4)
        case .invalidArgs(let msg):
            return ("invalid_args", msg, 3)
        case .commandFailed(let msg):
            return ("command_failed", msg, 2)
        case .invalidURL(let url):
            return ("invalid_args", "Invalid URL: \(url)", 3)
        }
    }

    private static func handleCLIError(_ error: CLIError) -> Never {
        let (code, message, status) = envelope(for: error)
        printError(code: code, message: message)
        exit(status)
    }
}
