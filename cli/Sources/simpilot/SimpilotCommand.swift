import Foundation

/// Single source of truth for subcommand dispatch, help rendering, and the
/// `ArgSpecHelpSyncTests` drift backstop. Every subcommand conforms; the
/// `Simpilot.registry` array of conforming types drives everything else.
///
/// `name` is derived from `argSpec.command` rather than a separate member so
/// the two can't drift apart — if they diverge, the command becomes
/// undispatchable via `registry.first(where:)` and fails loudly.
///
/// `Sendable` so `[any SimpilotCommand.Type]` is a Sendable existential array
/// under Swift 6 strict concurrency. Case-less enums (which every conforming
/// command is) satisfy this trivially.
protocol SimpilotCommand: Sendable {
    static var argSpec: ArgSpec { get }
    static var category: HelpCommands.Category { get }
    static var synopsis: String { get }
    static var description: String { get }
    static var example: String { get }

    static func run(context: RunContext) throws
}

extension SimpilotCommand {
    static var name: String { argSpec.command }
}

/// All invocation context a subcommand may need. Built once per `simpilot`
/// invocation in `Simpilot.main` and passed to the dispatched command's
/// `run(context:)`. Using a single struct instead of a union signature keeps
/// every command's `run` shape identical, at the cost of some fields being
/// unused by some commands (e.g. `start`/`stop`/`list` don't touch `client`,
/// only `help` reads `helpFormat`). That trade is fine: the compiler never
/// warns about unused struct fields, and adding a new per-command parameter
/// in the future is one-line change here rather than a signature cascade
/// across 23 files.
struct RunContext {
    let client: HTTPClient
    let args: [String]
    let pretty: Bool
    let port: Int
    let portExplicit: Bool
    let helpFormat: HelpFormat
}
