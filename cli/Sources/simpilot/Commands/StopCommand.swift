import Foundation

enum StopCommand: SimpilotCommand {
    static let argSpec = ArgSpec(
        command: "stop",
        flags: [
            .init("--port", .int),
            .init("--udid", .string),
            .init("--all", .bool),
        ]
    )
    static let category: HelpCommands.Category = .agent
    static let synopsis = "stop (--port <p> | --udid <u> | --all)"
    static let description = "Stop one or all running agents (requires a target)"
    static let example = "simpilot stop --all"

    /// Parsed + validated target intent. `parseStopTarget` is a pure function so
    /// tests can exercise the (D/F) invariants without touching the real registry.
    enum StopTarget: Equatable {
        case all
        case port(Int)
        case udid(String)
        case portAndUdid(Int, String)
    }

    // MARK: - Pure helpers (testable)

    /// Parse `args` into a `StopTarget`, applying (D) no-target rejection, the
    /// `--all` exclusivity rule, and the global `--port` propagation rules:
    ///
    /// - `portExplicit=false`: local flags only; empty → throw (D).
    /// - `portExplicit=true` with no local flags → synthesize `.port(globalPort)`.
    /// - `portExplicit=true` with local `--port p`: must equal `globalPort`, else
    ///   throw (conflict).
    /// - `portExplicit=true` with local `--udid u`: upgrade to
    ///   `.portAndUdid(globalPort, u)` so the (F) consistency check runs against
    ///   the registry.
    /// - `portExplicit=true` with `--all`: treated as conflict (explicit global
    ///   port is a single-target intent; `--all` is holistic). This case is not
    ///   in the Planner spec — flagged in the Implementer report as Open Q.
    ///
    /// Does NOT touch AgentRegistry. Default parameter values preserve test-site
    /// ergonomics for the pure local-flag paths.
    static func parseStopTarget(
        args: [String],
        globalPort: Int = 8222,
        portExplicit: Bool = false
    ) throws -> StopTarget {
        let parsed = try ArgParser.parse(args, spec: argSpec)
        let localPort = parsed.int("--port")
        let localUdid = parsed.string("--udid")
        let all = parsed.bool("--all")

        if all && (localPort != nil || localUdid != nil) {
            throw CLIError.invalidArgs(
                "stop: --all cannot be combined with --port or --udid"
            )
        }
        if all {
            if portExplicit {
                throw CLIError.invalidArgs(
                    "stop: --all cannot be combined with global --port \(globalPort); pick one target"
                )
            }
            return .all
        }

        if portExplicit, let lp = localPort, lp != globalPort {
            throw CLIError.invalidArgs(
                "stop: global --port \(globalPort) conflicts with local --port \(lp)"
            )
        }

        if let p = localPort, let u = localUdid {
            return .portAndUdid(p, u)
        }
        if let p = localPort {
            return .port(p)
        }
        if let u = localUdid {
            if portExplicit {
                return .portAndUdid(globalPort, u)
            }
            return .udid(u)
        }
        if portExplicit {
            return .port(globalPort)
        }
        throw CLIError.invalidArgs(
            "no target specified: use --port <p>, --udid <u>, or --all"
        )
    }

    /// Resolve a single-target `StopTarget` against a registry snapshot. Returns
    /// `nil` when the target names a port/udid that isn't registered (idempotent
    /// "already stopped" case), throws `.invalidArgs` for (F) mismatches.
    ///
    /// Caller must dispatch `.all` separately; calling this with `.all` is a
    /// programmer error (trapped via `preconditionFailure`).
    static func resolveSingle(target: StopTarget, in records: [AgentRecord]) throws -> AgentRecord? {
        switch target {
        case .all:
            preconditionFailure("resolveSingle must not be called with .all")
        case .port(let p):
            return records.first { $0.port == p }
        case .udid(let u):
            return records.first { $0.udid == u }
        case .portAndUdid(let p, let u):
            let byPort = records.first { $0.port == p }
            let byUdid = records.first { $0.udid == u }
            if let byPort, let byUdid, byPort.port == byUdid.port, byPort.udid == byUdid.udid {
                return byPort
            }
            throw CLIError.invalidArgs(
                "stop: --port \(p) and --udid \(u) refer to different agents (or one is not registered)"
            )
        }
    }

    /// Regex passed to `pgrep -f` to find simpilot-owned xcodebuild processes.
    ///
    /// The `AgentApp.xcodeproj` substring is unique to simpilot's agent project
    /// (`cli/Sources/simpilot/Commands/StartCommand.swift` spawns xcodebuild with
    /// `-project <dir>/AgentApp.xcodeproj -scheme AgentUITests`), so the combined
    /// `AgentApp.xcodeproj.*AgentUITests` pattern matches only our own runners.
    /// A bare `AgentUITests` pattern would also match any other repo's UI test
    /// runner that happened to share the scheme name, which was the problem
    /// Reviewer flagged as finding #4 (orphan cleanup was not actually bounded).
    ///
    /// This only ever finds the *xcodebuild* half of an agent. The simulator-side
    /// `AgentUITests-Runner` — the process that actually holds the listening
    /// socket — is swept by bundle identifier via `SimctlHelper`, which is exact
    /// where a `pgrep -f` pattern would have to guess.
    static let orphanPgrepPattern = #"AgentApp\.xcodeproj.*AgentUITests"#

    /// Pure orphan-detection helper: given newline-delimited `pgrep` output and
    /// a set of PIDs we already accounted for (registry snapshot), return the
    /// remaining AgentUITests PIDs that need scoped cleanup.
    ///
    /// Non-parseable lines and PIDs already in `excluding` are dropped. Uses
    /// `Character.isNewline` (not a raw `\n`/`\r` predicate) because Swift
    /// collapses CRLF into a single extended grapheme cluster, which the naive
    /// predicate would skip over.
    static func detectOrphans(pgrepOutput: String, excluding knownPIDs: Set<Int32>) -> [Int32] {
        return pgrepOutput
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !knownPIDs.contains($0) }
    }

    // MARK: - Entry point

    static func run(context: RunContext) throws {
        let target = try parseStopTarget(
            args: context.args,
            globalPort: context.port,
            portExplicit: context.portExplicit
        )
        let pretty = context.pretty

        if case .all = target {
            try stopAllAgents(pretty: pretty)
            return
        }

        // `allRecords`, not `load`: a record whose xcodebuild has died is exactly
        // the one whose runner is still holding the port. Pruning it here would
        // make `stop --port N` print "already stopped" and leave N bound.
        let records = try AgentRegistry.allRecords()
        guard let record = try resolveSingle(target: target, in: records) else {
            printAlreadyStoppedEnvelope(target: target, pretty: pretty)
            return
        }

        switch target {
        case .udid:
            _ = try AgentRegistry.remove(udid: record.udid)
        case .port, .portAndUdid:
            _ = try AgentRegistry.remove(port: record.port)
        case .all:
            preconditionFailure("unreachable: .all is dispatched above")
        }
        teardownAgent(record)

        let result: [String: Any] = [
            "success": true,
            "data": [
                "message": "Agent stopped",
                "port": record.port,
                "udid": record.udid,
                "pid": Int(record.pid),
                "cloneDeleted": record.isClone,
            ] as [String: Any],
            "error": NSNull()
        ]
        printJSON(result, pretty: pretty)
    }

    // MARK: - Stop All

    private static func stopAllAgents(pretty: Bool) throws {
        // `stop --all` is the tool you reach for *because* things are broken, so
        // an unreadable registry must not abort it. Fall back to an empty
        // snapshot: the pgrep + runner sweeps below need no registry at all, and
        // they are the only cleanup available in that state.
        var records: [AgentRecord] = []
        var registryError: String?
        do {
            records = try AgentRegistry.removeAll()
        } catch {
            registryError = "\(error)"
            FileHandle.standardError.write(Data(
                "simpilot: registry unusable, sweeping orphans only (\(error))\n".utf8
            ))
        }

        var stopped: [[String: Any]] = []
        for record in records {
            teardownAgent(record)
            stopped.append([
                "port": record.port,
                "udid": record.udid,
                "pid": Int(record.pid),
                "cloneDeleted": record.isClone,
            ])
        }

        // (E revised) Bounded orphan cleanup: after SIGTERMing the registry
        // snapshot, `pgrep -f AgentUITests` for any remaining processes that the
        // registry didn't know about and SIGTERM only those. Replaces the blind
        // `pkill -f AgentUITests` fallback that could kill unrelated test runners.
        let knownPIDs = Set(records.map { $0.pid })
        let orphans = pgrepAgentUITestsOrphans(excluding: knownPIDs)
        for pid in orphans {
            kill(pid, SIGTERM)
        }

        // pgrep only ever sees the xcodebuild half. Sweep the simulator-side
        // runners too — they outlive their xcodebuild and keep the port bound.
        let knownUDIDs = Set(records.filter { !$0.isPhysical }.map(\.udid))
        let orphanRunners = SimctlHelper.terminateOrphanRunners(excluding: knownUDIDs)

        let orphanCount = orphans.count + orphanRunners.count
        let agentCountMessage: String
        if stopped.isEmpty && orphanCount == 0 {
            agentCountMessage = "No running agents found"
        } else if stopped.isEmpty {
            agentCountMessage = "\(orphanCount) orphan agent(s) cleaned"
        } else if orphanCount == 0 {
            agentCountMessage = "\(stopped.count) agent(s) stopped"
        } else {
            agentCountMessage = "\(stopped.count) agent(s) stopped, \(orphanCount) orphan(s) cleaned"
        }

        var data: [String: Any] = [
            "message": agentCountMessage,
            "agents": stopped,
            "orphans_cleaned": orphans.count,
            "orphan_runners_cleaned": orphanRunners.count,
        ]
        // Say so in the envelope, not just on stderr: "No running agents found"
        // reads very differently when the registry could not be opened at all.
        if let registryError {
            data["registry_error"] = registryError
        }

        let result: [String: Any] = [
            "success": true,
            "data": data,
            "error": NSNull()
        ]
        printJSON(result, pretty: pretty)
    }

    /// Spawns `pgrep -f AgentUITests`, reads stdout, and returns orphan PIDs
    /// (those not present in `knownPIDs`). Returns an empty array on any error —
    /// we never want this helper to crash `stop --all`; worst case, the orphan
    /// cleanup silently degrades to the pre-revision behavior (no-op).
    private static func pgrepAgentUITestsOrphans(excluding knownPIDs: Set<Int32>) -> [Int32] {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", orphanPgrepPattern]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return detectOrphans(pgrepOutput: output, excluding: knownPIDs)
    }

    // MARK: - Helpers

    /// SIGTERM the `xcodebuild` process, then stop the simulator-side runner it
    /// left behind. Killing only `xcodebuild` leaves `AgentUITests-Runner`
    /// holding the port, so the next `start` on that port fails.
    private static func teardownAgent(_ record: AgentRecord) {
        kill(record.pid, SIGTERM)
        if !record.isPhysical && !record.udid.isEmpty {
            SimctlHelper.terminateRunner(udid: record.udid)
        }
        if record.isClone {
            SimctlHelper.deleteClone(udid: record.udid)
        }
    }

    private static func printAlreadyStoppedEnvelope(target: StopTarget, pretty: Bool) {
        let message: String
        switch target {
        case .port(let p):
            message = "No running agent on port \(p)"
        case .udid(let u):
            message = "No running agent with UDID \(u)"
        case .portAndUdid, .all:
            preconditionFailure("printAlreadyStoppedEnvelope only valid for .port/.udid")
        }
        let result: [String: Any] = [
            "success": true,
            "data": ["message": message],
            "error": NSNull()
        ]
        printJSON(result, pretty: pretty)
    }
}
