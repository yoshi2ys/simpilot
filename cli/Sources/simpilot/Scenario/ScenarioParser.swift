import Foundation

// MARK: - Parse Error

struct ScenarioParseError: Error, CustomStringConvertible {
    let message: String
    let line: Int?

    var description: String {
        if let line { return "scenario parse error at line \(line): \(message)" }
        return "scenario parse error: \(message)"
    }
}

// MARK: - Parser

enum ScenarioParser {

    /// Parse a `YAMLValue` (from `YAMLParser.parse`) into a `ScenarioFile`.
    /// `cliVars` are `key=val` pairs from `--var` that override YAML `variables`.
    static func parse(_ yaml: YAMLValue, cliVars: [String: String] = [:]) throws -> ScenarioFile {
        guard yaml.mappingValue != nil else {
            throw ScenarioParseError(message: "root must be a mapping", line: nil)
        }

        let name = yaml["name"]?.stringValue ?? "Untitled"
        let config = try parseConfig(yaml["config"])
        var variables = parseVariables(yaml["variables"])

        // CLI vars override YAML vars
        for (k, v) in cliVars { variables[k] = v }

        guard let scenariosYAML = yaml["scenarios"]?.sequenceValue else {
            throw ScenarioParseError(message: "missing 'scenarios' sequence", line: nil)
        }

        let scenarios = try scenariosYAML.enumerated().map { (i, s) in
            try parseScenario(s, variables: variables, index: i)
        }

        return ScenarioFile(name: name, config: config, variables: variables, scenarios: scenarios)
    }

    // MARK: - Config

    private static func parseConfig(_ yaml: YAMLValue?) throws -> ScenarioConfig {
        var config = ScenarioConfig()
        guard let mapping = yaml?.mappingValue else { return config }

        for (key, value) in mapping {
            guard let s = value.stringValue else { continue }
            switch key {
            case "timeout":
                guard let d = Double(s) else {
                    throw ScenarioParseError(message: "config.timeout must be a number", line: nil)
                }
                config.timeout = d
            case "stop_on_failure":
                config.stopOnFailure = try requireBool(s, field: "config.stop_on_failure")
            case "screenshot_on_failure":
                config.screenshotOnFailure = try requireBool(s, field: "config.screenshot_on_failure")
            case "screenshot_dir":
                config.screenshotDir = s
            default:
                break
            }
        }
        return config
    }

    // MARK: - Variables

    private static func parseVariables(_ yaml: YAMLValue?) -> [String: String] {
        guard let pairs = yaml?.mappingValue else { return [:] }
        var vars: [String: String] = [:]
        for (k, v) in pairs {
            vars[k] = v.stringValue ?? ""
        }
        return vars
    }

    // MARK: - Scenario

    private static func parseScenario(_ yaml: YAMLValue, variables: [String: String], index: Int) throws -> Scenario {
        guard yaml.mappingValue != nil else {
            throw ScenarioParseError(message: "scenario[\(index)] must be a mapping", line: nil)
        }

        let name = yaml["name"]?.stringValue ?? "Scenario \(index + 1)"

        guard let stepsYAML = yaml["steps"]?.sequenceValue else {
            throw ScenarioParseError(message: "scenario '\(name)' missing 'steps'", line: nil)
        }

        let steps = try stepsYAML.enumerated().map { (i, stepYAML) in
            try parseStep(stepYAML, variables: variables, stepIndex: i, scenarioName: name)
        }

        return Scenario(name: name, steps: steps)
    }

    // MARK: - Step

    private static func parseStep(_ yaml: YAMLValue, variables: [String: String],
                                   stepIndex: Int, scenarioName: String) throws -> Step {
        guard let pairs = yaml.mappingValue, let (key, value) = pairs.first else {
            throw ScenarioParseError(message: "\(scenarioName) step[\(stepIndex)] must be a mapping", line: nil)
        }

        let lineNumber = stepIndex + 1 // approximate
        let action = try parseAction(key: key, value: value, variables: variables, lineNumber: lineNumber)
        return Step(action: action, lineNumber: lineNumber)
    }

    // MARK: - Actions

    private static func parseAction(key: String, value: YAMLValue,
                                     variables: [String: String],
                                     lineNumber: Int) throws -> StepAction {
        switch key {
        case "launch":
            return .launch(bundleId: try requireScalar(value, key: key, variables: variables))
        case "terminate":
            return .terminate(bundleId: try requireScalar(value, key: key, variables: variables))
        case "activate":
            return .activate(bundleId: try requireScalar(value, key: key, variables: variables))
        case "tap":
            if let s = value.stringValue {
                return .tap(query: substitute(s, variables: variables), waitUntil: nil, timeout: nil)
            }
            return .tap(
                query: try requireField(value, "query", variables: variables),
                waitUntil: optionalField(value, "wait_until", variables: variables),
                timeout: try optionalDouble(value, "timeout")
            )
        case "type":
            if let s = value.stringValue {
                return .type(text: substitute(s, variables: variables), into: nil, method: nil)
            }
            return .type(
                text: try requireField(value, "text", variables: variables),
                into: optionalField(value, "into", variables: variables),
                method: optionalField(value, "method", variables: variables)
            )
        case "swipe":
            if let s = value.stringValue {
                return .swipe(direction: substitute(s, variables: variables), on: nil, velocity: nil)
            }
            return .swipe(
                direction: try requireField(value, "direction", variables: variables),
                on: optionalField(value, "on", variables: variables),
                velocity: optionalField(value, "velocity", variables: variables)
            )
        case "scroll_to":
            if let s = value.stringValue {
                return .scrollTo(query: substitute(s, variables: variables), direction: nil, maxSwipes: nil)
            }
            return .scrollTo(
                query: try requireField(value, "query", variables: variables),
                direction: optionalField(value, "direction", variables: variables),
                maxSwipes: try optionalInt(value, "max_swipes")
            )
        case "longpress":
            if let s = value.stringValue {
                return .longpress(query: substitute(s, variables: variables), duration: nil)
            }
            return .longpress(
                query: try requireField(value, "query", variables: variables),
                duration: try optionalDouble(value, "duration")
            )
        case "doubletap":
            return .doubletap(query: try requireScalar(value, key: key, variables: variables))
        case "drag":
            return .drag(
                query: optionalField(value, "query", variables: variables),
                to: optionalField(value, "to", variables: variables),
                toX: try optionalDouble(value, "to_x"),
                toY: try optionalDouble(value, "to_y"),
                fromX: try optionalDouble(value, "from_x"),
                fromY: try optionalDouble(value, "from_y"),
                duration: try optionalDouble(value, "duration")
            )
        case "pinch":
            guard let scaleVal = try optionalDouble(value, "scale") else {
                throw ScenarioParseError(message: "'pinch' requires 'scale'", line: lineNumber)
            }
            return .pinch(
                query: optionalField(value, "query", variables: variables),
                scale: scaleVal,
                velocity: optionalField(value, "velocity", variables: variables)
            )
        case "wait":
            if let s = value.stringValue {
                return .wait(query: substitute(s, variables: variables), timeout: nil, gone: false)
            }
            return .wait(
                query: try requireField(value, "query", variables: variables),
                timeout: try optionalDouble(value, "timeout"),
                gone: try optionalBool(value, "gone")
            )
        case "assert":
            return .assert(
                predicate: try requireField(value, "predicate", variables: variables),
                query: try requireField(value, "query", variables: variables),
                expected: optionalField(value, "expected", variables: variables),
                timeout: try optionalDouble(value, "timeout")
            )
        case "screenshot":
            if value.stringValue != nil {
                // `- screenshot: /tmp/s.png` shorthand
                return .screenshot(
                    file: value.stringValue.map { substitute($0, variables: variables) },
                    scale: nil, element: nil, format: nil, quality: nil
                )
            }
            return .screenshot(
                file: optionalField(value, "file", variables: variables),
                scale: optionalField(value, "scale", variables: variables),
                element: optionalField(value, "element", variables: variables),
                format: optionalField(value, "format", variables: variables),
                quality: try optionalInt(value, "quality")
            )
        case "elements":
            return .elements(
                level: try optionalInt(value, "level"),
                type: optionalField(value, "type", variables: variables),
                contains: optionalField(value, "contains", variables: variables)
            )
        case "sleep":
            guard let s = value.stringValue, let d = Double(s) else {
                throw ScenarioParseError(message: "'sleep' requires a numeric value", line: lineNumber)
            }
            return .sleep(seconds: d)
        default:
            throw ScenarioParseError(message: "unknown step type '\(key)'", line: lineNumber)
        }
    }

    // MARK: - Variable Substitution

    // Compiled once — substitute() is called per-field per-step.
    private static let envPattern = try! NSRegularExpression(pattern: #"\$\{env\.([^}]+)\}"#)

    static func substitute(_ s: String, variables: [String: String]) -> String {
        var result = s
        for (key, val) in variables {
            result = result.replacingOccurrences(of: "${\(key)}", with: val)
        }
        let range = NSRange(result.startIndex..., in: result)
        let matches = envPattern.matches(in: result, range: range).reversed()
        for match in matches {
            guard let keyRange = Range(match.range(at: 1), in: result) else { continue }
            let envKey = String(result[keyRange])
            let envVal = ProcessInfo.processInfo.environment[envKey] ?? ""
            let fullRange = Range(match.range, in: result)!
            result.replaceSubrange(fullRange, with: envVal)
        }
        return result
    }

    // MARK: - Field Helpers

    private static func requireScalar(_ value: YAMLValue, key: String,
                                       variables: [String: String]) throws -> String {
        // Accept both scalar and mapping with "query" field for consistency
        if let s = value.stringValue {
            return substitute(s, variables: variables)
        }
        if let q = value["query"]?.stringValue {
            return substitute(q, variables: variables)
        }
        throw ScenarioParseError(message: "'\(key)' requires a string value", line: nil)
    }

    private static func requireField(_ value: YAMLValue, _ field: String,
                                      variables: [String: String]) throws -> String {
        guard let s = value[field]?.stringValue else {
            throw ScenarioParseError(message: "missing required field '\(field)'", line: nil)
        }
        return substitute(s, variables: variables)
    }

    private static func optionalField(_ value: YAMLValue, _ field: String,
                                       variables: [String: String]) -> String? {
        guard let s = value[field]?.stringValue else { return nil }
        return substitute(s, variables: variables)
    }

    private static func requireBool(_ s: String, field: String) throws -> Bool {
        switch s.lowercased() {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default:
            throw ScenarioParseError(message: "'\(field)' must be a boolean, got '\(s)'", line: nil)
        }
    }

    private static func optionalDouble(_ value: YAMLValue, _ field: String) throws -> Double? {
        guard let s = value[field]?.stringValue else { return nil }
        guard let d = Double(s) else {
            throw ScenarioParseError(message: "'\(field)' must be a number, got '\(s)'", line: nil)
        }
        return d
    }

    private static func optionalInt(_ value: YAMLValue, _ field: String) throws -> Int? {
        guard let s = value[field]?.stringValue else { return nil }
        guard let n = Int(s) else {
            throw ScenarioParseError(message: "'\(field)' must be an integer, got '\(s)'", line: nil)
        }
        return n
    }

    private static func optionalBool(_ value: YAMLValue, _ field: String) throws -> Bool {
        guard let s = value[field]?.stringValue else { return false }
        switch s.lowercased() {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default:
            throw ScenarioParseError(message: "'\(field)' must be a boolean, got '\(s)'", line: nil)
        }
    }
}

// MARK: - CLI --var Parsing

extension ScenarioParser {
    /// Parse `--var "key=val,key2=val2"` into a dictionary.
    static func parseCLIVars(_ raw: String) -> [String: String] {
        var vars: [String: String] = [:]
        for pair in raw.split(separator: ",") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                vars[String(parts[0]).trimmingCharacters(in: .whitespaces)] =
                    String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        return vars
    }
}
