import Foundation

enum RunCommand: SimpilotCommand {
    static let argSpec = ArgSpec(
        command: "run",
        positionals: [.init(name: "file", required: true)],
        flags: [
            .init("--json", .bool),
            .init("--var", .string),
            .init("--timeout", .double),
            .init("--screenshot-dir", .string),
        ]
    )
    static let category: HelpCommands.Category = .utility
    static let synopsis = "run <file> [--json] [--var <key=val,...>] [--timeout <s>] [--screenshot-dir <path>]"
    static let description = "Run a YAML scenario file with assertions"
    static let example = "simpilot run test.yml --json"

    static func run(context: RunContext) throws {
        let parsed = try ArgParser.parse(context.args, spec: argSpec)
        let filePath = parsed.positionals[0]
        let jsonOutput = parsed.bool("--json")

        let fileURL = URL(fileURLWithPath: filePath)
        let contents: String
        do {
            contents = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            throw CLIError.invalidArgs("cannot read file '\(filePath)': \(error.localizedDescription)")
        }

        let yamlValue: YAMLValue
        do {
            yamlValue = try YAMLParser.parse(contents)
        } catch let e as YAMLParseError {
            throw CLIError.invalidArgs(e.description)
        }

        let cliVars = parsed.string("--var").map(ScenarioParser.parseCLIVars) ?? [:]

        let scenarioFile: ScenarioFile
        do {
            scenarioFile = try ScenarioParser.parse(yamlValue, cliVars: cliVars)
        } catch let e as ScenarioParseError {
            throw CLIError.invalidArgs(e.description)
        }

        var config = scenarioFile.config
        if let timeout = parsed.double("--timeout") {
            config.timeout = timeout
        }
        if let dir = parsed.string("--screenshot-dir") {
            config.screenshotDir = dir
        }

        let file = ScenarioFile(
            name: scenarioFile.name,
            config: config,
            variables: scenarioFile.variables,
            scenarios: scenarioFile.scenarios
        )

        let result = ScenarioRunner.run(file: file, client: context.client)

        if jsonOutput {
            RunReporter.reportJSON(result, pretty: context.pretty)
        } else {
            RunReporter.reportTerminal(result)
        }

        // Exit directly — the report already contains all failure details.
        // Throwing CLIError.commandFailed would produce a second JSON envelope
        // on stdout, corrupting --json output and confusing terminal mode.
        if result.totalFailed > 0 {
            exit(2)
        }
    }
}
