import Foundation

/// Declarative spec for a CLI subcommand. Drives both `ArgParser.parse` and the
/// help-synopsis backstop test (which asserts every flag in `ArgSpec.flags`
/// appears in the corresponding `HelpCommands` synopsis string).
///
/// Strict by design: unknown flags, missing values, type-coercion failures, and
/// unexpected positionals all surface as `CLIError.invalidArgs` (exit 3). There
/// is no env-gated lenient mode — simpilot is solo-user, no BC obligations.
struct ArgSpec {
    let command: String
    let positionals: [Positional]
    let flags: [Flag]
    /// When true, additional positionals beyond `positionals.count` are accepted
    /// (e.g. `batch <json...>` joins multiple shell words back into one JSON blob).
    let allowsExtraPositionals: Bool

    init(
        command: String,
        positionals: [Positional] = [],
        flags: [Flag] = [],
        allowsExtraPositionals: Bool = false
    ) {
        self.command = command
        self.positionals = positionals
        self.flags = flags
        self.allowsExtraPositionals = allowsExtraPositionals
    }

    struct Positional {
        let name: String
        let required: Bool
    }

    struct Flag {
        let name: String
        let kind: Kind

        init(_ name: String, _ kind: Kind) {
            self.name = name
            self.kind = kind
        }
    }

    enum Kind {
        case bool                          // --gone, --pretty
        case string                        // --device <name>
        case int                           // --level <n>
        case double                        // --timeout <s>
        case optionalInt(default: Int)     // --clone [N]   (default 1)
    }
}

/// Result of a successful `ArgParser.parse` call. Positional arguments are
/// returned in source order; flag values are looked up by name with type-safe
/// accessors. Missing optional flags return `nil` / `false`.
struct ParsedArgs {
    let positionals: [String]
    private let flagValues: [String: FlagValue]

    enum FlagValue {
        case bool(Bool)
        case string(String)
        case int(Int)
        case double(Double)
    }

    init(positionals: [String], flagValues: [String: FlagValue]) {
        self.positionals = positionals
        self.flagValues = flagValues
    }

    func bool(_ name: String) -> Bool {
        if case .bool(let v) = flagValues[name] { return v }
        return false
    }

    func string(_ name: String) -> String? {
        if case .string(let v) = flagValues[name] { return v }
        return nil
    }

    func int(_ name: String) -> Int? {
        if case .int(let v) = flagValues[name] { return v }
        return nil
    }

    func double(_ name: String) -> Double? {
        if case .double(let v) = flagValues[name] { return v }
        return nil
    }
}

enum ArgParser {
    /// Parse `args` against `spec`. See `ArgSpec` doc for the strictness contract.
    static func parse(_ args: [String], spec: ArgSpec) throws -> ParsedArgs {
        let flagsByName: [String: ArgSpec.Flag] = Dictionary(
            uniqueKeysWithValues: spec.flags.map { ($0.name, $0) }
        )
        var positionals: [String] = []
        var flagValues: [String: ParsedArgs.FlagValue] = [:]
        var i = 0
        var afterTerminator = false

        while i < args.count {
            let arg = args[i]

            if afterTerminator {
                positionals.append(arg)
                i += 1
                continue
            }

            if arg == "--" {
                afterTerminator = true
                i += 1
                continue
            }

            if isFlagLike(arg) {
                guard let flag = flagsByName[arg] else {
                    throw CLIError.invalidArgs(unknownFlagMessage(arg, spec: spec))
                }
                switch flag.kind {
                case .bool:
                    flagValues[flag.name] = .bool(true)
                    i += 1
                case .string:
                    let raw = try requireValue(args: args, index: i, flag: arg)
                    flagValues[flag.name] = .string(raw)
                    i += 2
                case .int:
                    let raw = try requireValue(args: args, index: i, flag: arg)
                    guard let n = Int(raw) else {
                        throw CLIError.invalidArgs(
                            "flag '\(arg)' expects an integer, got '\(raw)'"
                        )
                    }
                    flagValues[flag.name] = .int(n)
                    i += 2
                case .double:
                    let raw = try requireValue(args: args, index: i, flag: arg)
                    guard let n = Double(raw) else {
                        throw CLIError.invalidArgs(
                            "flag '\(arg)' expects a number, got '\(raw)'"
                        )
                    }
                    flagValues[flag.name] = .double(n)
                    i += 2
                case .optionalInt(let defaultValue):
                    // Lookahead: consume next token only if it is neither another flag
                    // nor the `--` terminator. A non-flag, non-terminator token MUST
                    // parse as Int — failing to do so is a typo, not a missing value.
                    let hasNext = i + 1 < args.count
                    let nextIsConsumable = hasNext
                        && !isFlagLike(args[i + 1])
                        && args[i + 1] != "--"
                    if nextIsConsumable {
                        let raw = args[i + 1]
                        guard let n = Int(raw) else {
                            throw CLIError.invalidArgs(
                                "flag '\(arg)' expects an integer or no value, got '\(raw)'"
                            )
                        }
                        flagValues[flag.name] = .int(n)
                        i += 2
                    } else {
                        flagValues[flag.name] = .int(defaultValue)
                        i += 1
                    }
                }
            } else {
                positionals.append(arg)
                i += 1
            }
        }

        try validatePositionals(positionals, spec: spec)
        return ParsedArgs(positionals: positionals, flagValues: flagValues)
    }

    // MARK: - Helpers

    /// A token is "flag-like" iff it starts with exactly two ASCII hyphens (0x2D)
    /// followed by at least one non-hyphen byte. This deliberately rejects:
    ///   - bare `--` (the POSIX terminator, handled separately by the caller)
    ///   - `---foo`        (treated as positional)
    ///   - `—foo` U+2014   (em dash from typographic paste — UTF-8 bytes are E2 80 94, not 2D)
    ///   - `-foo`          (single dash; we don't support short flags)
    static func isFlagLike(_ s: String) -> Bool {
        var it = s.utf8.makeIterator()
        guard it.next() == 0x2D, it.next() == 0x2D else { return false }
        guard let third = it.next() else { return false }
        return third != 0x2D
    }

    private static func requireValue(args: [String], index i: Int, flag: String) throws -> String {
        guard i + 1 < args.count else {
            throw CLIError.invalidArgs("flag '\(flag)' requires a value")
        }
        return args[i + 1]
    }

    private static func unknownFlagMessage(_ arg: String, spec: ArgSpec) -> String {
        let helpHint: String = (spec.command == "simpilot")
            ? "Run 'simpilot --help' for usage."
            : "Run 'simpilot help \(spec.command)' for usage."
        return "unknown flag '\(arg)' for command '\(spec.command)'. \(helpHint)"
    }

    private static func validatePositionals(_ positionals: [String], spec: ArgSpec) throws {
        let required = spec.positionals.filter { $0.required }.count
        let total = spec.positionals.count

        if positionals.count < required {
            let missing = spec.positionals[positionals.count..<required]
                .map { "<\($0.name)>" }
                .joined(separator: " ")
            throw CLIError.invalidArgs(
                "\(spec.command): missing required argument(s): \(missing)"
            )
        }

        if !spec.allowsExtraPositionals && positionals.count > total {
            let extra = positionals[total...].map { "'\($0)'" }.joined(separator: ", ")
            let shape = positionalShape(spec)
            throw CLIError.invalidArgs(
                "\(spec.command): unexpected argument: \(extra) (\(spec.command) \(shape))"
            )
        }
    }

    /// Renders the positional shape for error messages, e.g. "takes 1 positional: <query>"
    /// or "takes 2 positionals: <predicate> <query> [<expected>]". Returns "takes no positionals"
    /// for commands with an empty `positionals` list.
    private static func positionalShape(_ spec: ArgSpec) -> String {
        guard !spec.positionals.isEmpty else {
            return "takes no positional arguments"
        }
        let required = spec.positionals.filter { $0.required }
        let optional = spec.positionals.filter { !$0.required }
        let parts = spec.positionals.map { p -> String in
            p.required ? "<\(p.name)>" : "[<\(p.name)>]"
        }
        let count: String
        if optional.isEmpty {
            count = "takes \(required.count) positional\(required.count == 1 ? "" : "s")"
        } else if required.isEmpty {
            count = "takes up to \(optional.count) positional\(optional.count == 1 ? "" : "s")"
        } else {
            count = "takes \(required.count)–\(spec.positionals.count) positionals"
        }
        return "\(count): \(parts.joined(separator: " "))"
    }
}
