import Foundation

enum ElementsCommand: SimpilotCommand {
    static let argSpec = ArgSpec(
        command: "elements",
        flags: [
            .init("--app", .string),
            .init("--depth", .int),
            .init("--level", .int),
            .init("--actionable", .bool),
            .init("--compact", .bool),
            .init("--type", .string),
            .init("--contains", .string),
            .init("--format", .string),
        ]
    )
    static let category: HelpCommands.Category = .observation
    static let synopsis = "elements [--app <bundleId>] [--depth <n>] [--level 0|1|2|3] [--actionable] [--compact] [--type <types>] [--contains <text>] [--format json|outline]"
    static let description = "List UI elements at given detail level (--type and --contains filter level 1 only; --format outline prints compact text and renders level 1 only)"
    static let example = "simpilot elements --format outline --type button,switch"

    /// Build the GET path from CLI args. Exposed for testing.
    static func buildPath(from args: [String]) throws -> String {
        try buildPath(from: try ArgParser.parse(args, spec: argSpec))
    }

    static func buildPath(from parsed: ParsedArgs) throws -> String {
        var components = URLComponents()
        components.path = "/elements"
        var queryItems: [URLQueryItem] = []
        if let bundleId = parsed.string("--app") {
            queryItems.append(URLQueryItem(name: "bundleId", value: bundleId))
        }
        if let depth = parsed.int("--depth") {
            queryItems.append(URLQueryItem(name: "depth", value: "\(depth)"))
        }
        if let level = parsed.int("--level") {
            queryItems.append(URLQueryItem(name: "level", value: "\(level)"))
        } else if parsed.bool("--actionable") {
            queryItems.append(URLQueryItem(name: "mode", value: "actionable"))
        } else if parsed.bool("--compact") {
            queryItems.append(URLQueryItem(name: "mode", value: "compact"))
        }
        if let type = parsed.string("--type") {
            queryItems.append(URLQueryItem(name: "type", value: type))
        }
        if let contains = parsed.string("--contains") {
            queryItems.append(URLQueryItem(name: "contains", value: contains))
        }
        if let format = parsed.string("--format") {
            queryItems.append(URLQueryItem(name: "format", value: try ElementsFormatArg.validate(format)))
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        return components.string ?? "/elements"
    }

    static func run(context: RunContext) throws {
        let parsed = try ArgParser.parse(context.args, spec: argSpec)
        let data = try context.client.get(try buildPath(from: parsed))
        if try isOutline(parsed) {
            try decodeAndPrintPlainText(data: data, field: "outline", pretty: context.pretty)
        } else {
            try decodeAndPrint(data: data, pretty: context.pretty)
        }
    }

    /// Whether this invocation asked for outline text rather than an envelope.
    ///
    /// Derived from the same parse and the same validator that `buildPath` uses,
    /// so the two cannot disagree about what was requested. A second parse here
    /// would let a future second way to select the format (a `--outline` alias,
    /// an env default) reach the URL but not the printing path — the envelope
    /// would then be printed with the outline escaped inside it, at exit 0, which
    /// is the exact outcome this format exists to avoid.
    static func isOutline(_ parsed: ParsedArgs) throws -> Bool {
        guard let raw = parsed.string("--format") else { return false }
        return try ElementsFormatArg.validate(raw) == "outline"
    }

    /// Args-based convenience for tests.
    static func isOutline(_ args: [String]) -> Bool {
        guard let parsed = try? ArgParser.parse(args, spec: argSpec) else { return false }
        return (try? isOutline(parsed)) ?? false
    }
}

/// Mirrors `ScaleArg`/`FormatArg`/`QualityArg` in `ScreenshotCommand.swift`:
/// one validator type per enum-valued flag, quoting the offending value back.
enum ElementsFormatArg {
    static func validate(_ value: String) throws -> String {
        let lower = value.lowercased()
        guard lower == "json" || lower == "outline" else {
            throw CLIError.invalidArgs("--format must be 'json' or 'outline' (got '\(value)')")
        }
        return lower
    }
}
