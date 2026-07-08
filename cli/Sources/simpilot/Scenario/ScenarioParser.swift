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
        guard let yaml else { return config }
        guard let mapping = yaml.mappingValue else {
            throw ScenarioParseError(message: "config must be a mapping", line: nil)
        }

        for (key, value) in mapping {
            guard let s = value.stringValue else {
                switch key {
                case "timeout", "stop_on_failure", "screenshot_on_failure", "screenshot_dir":
                    throw ScenarioParseError(message: "config.\(key) must be a scalar value", line: nil)
                default:
                    continue
                }
            }
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
        let stepNumber = stepIndex + 1
        guard let pairs = yaml.mappingValue, let (key, value) = pairs.first else {
            throw ScenarioParseError(message: "\(scenarioName) step \(stepNumber) must be a mapping", line: nil)
        }
        if pairs.count > 1 {
            throw ScenarioParseError(
                message: "\(scenarioName) step \(stepNumber) must have exactly one action key, got \(pairs.count)",
                line: nil
            )
        }
        let action = try parseAction(key: key, value: value, variables: variables, stepNumber: stepNumber)
        return Step(action: action, stepNumber: stepNumber)
    }

    // MARK: - Actions

    /// Fields each action's mapping form accepts. A mapping-form action carrying
    /// any other key is a typo (`timout:`) that would otherwise be silently
    /// dropped and default — so it's rejected (A20). Scalar-form actions
    /// (`tap: General`) and `sleep` (scalar only) aren't listed and skip the check.
    private static let allowedFields: [String: Set<String>] = [
        "launch": ["query"],
        "terminate": ["query"],
        "activate": ["query"],
        "doubletap": ["query"],
        "tap": ["query", "wait_until", "timeout"],
        "type": ["text", "into", "method"],
        "swipe": ["direction", "on", "velocity"],
        "scroll_to": ["query", "direction", "max_swipes"],
        "longpress": ["query", "duration"],
        "drag": ["query", "to", "to_x", "to_y", "from_x", "from_y", "duration"],
        "pinch": ["query", "scale", "velocity"],
        "wait": ["query", "timeout", "gone"],
        "assert": ["predicate", "query", "expected", "timeout"],
        "screenshot": ["file", "scale", "element", "format", "quality"],
        "elements": ["level", "type", "contains"],
    ]

    private static func parseAction(key: String, value: YAMLValue,
                                     variables: [String: String],
                                     stepNumber: Int) throws -> StepAction {
        // Reject unknown/typo'd fields on the mapping form before dispatch, so a
        // misspelled key surfaces instead of silently defaulting (A20).
        if let allowed = allowedFields[key], let pairs = value.mappingValue {
            for (field, _) in pairs where !allowed.contains(field) {
                throw ScenarioParseError(
                    message: "step \(stepNumber): '\(key)' has unknown field '\(field)'; allowed: \(allowed.sorted().joined(separator: ", "))",
                    line: nil
                )
            }
        }
        switch key {
        case "launch":
            return .launch(bundleId: try requireScalar(value, key: key, variables: variables))
        case "terminate":
            return .terminate(bundleId: try requireScalar(value, key: key, variables: variables))
        case "activate":
            return .activate(bundleId: try requireScalar(value, key: key, variables: variables))
        case "tap":
            if let s = shorthandScalar(value) {
                return .tap(query: substitute(s, variables: variables), waitUntil: nil, timeout: nil)
            }
            return .tap(
                query: try requireField(value, "query", variables: variables),
                waitUntil: optionalField(value, "wait_until", variables: variables),
                timeout: try optionalDouble(value, "timeout")
            )
        case "type":
            // `type` is the one action where a whitespace-only value is
            // legitimate (typing a literal space), so it keeps the raw scalar
            // and allows an empty `text` field.
            if let s = value.stringValue {
                return .type(text: substitute(s, variables: variables), into: nil, method: nil)
            }
            return .type(
                text: try requireField(value, "text", variables: variables, allowEmpty: true),
                into: optionalField(value, "into", variables: variables),
                method: optionalField(value, "method", variables: variables)
            )
        case "swipe":
            if let s = shorthandScalar(value) {
                return .swipe(direction: substitute(s, variables: variables), on: nil, velocity: nil)
            }
            return .swipe(
                direction: try requireField(value, "direction", variables: variables),
                on: optionalField(value, "on", variables: variables),
                velocity: optionalField(value, "velocity", variables: variables)
            )
        case "scroll_to":
            if let s = shorthandScalar(value) {
                return .scrollTo(query: substitute(s, variables: variables), direction: nil, maxSwipes: nil)
            }
            return .scrollTo(
                query: try requireField(value, "query", variables: variables),
                direction: optionalField(value, "direction", variables: variables),
                maxSwipes: try optionalInt(value, "max_swipes")
            )
        case "longpress":
            if let s = shorthandScalar(value) {
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
                throw ScenarioParseError(message: "step \(stepNumber): 'pinch' requires 'scale'", line: nil)
            }
            return .pinch(
                query: optionalField(value, "query", variables: variables),
                scale: scaleVal,
                velocity: optionalField(value, "velocity", variables: variables)
            )
        case "wait":
            if let s = shorthandScalar(value) {
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
                throw ScenarioParseError(message: "step \(stepNumber): 'sleep' requires a numeric value", line: nil)
            }
            return .sleep(seconds: d)
        default:
            throw ScenarioParseError(message: "step \(stepNumber): unknown step type '\(key)'", line: nil)
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

    /// A scalar with no real content — empty or whitespace-only. Used to reject
    /// `- tap:` / `{query: ""}` instead of silently posting an empty argument
    /// (A19). `type` opts out, since a literal space is a valid thing to type.
    private static func isBlank(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func requireScalar(_ value: YAMLValue, key: String,
                                       variables: [String: String]) throws -> String {
        // Accept both a scalar and a mapping with a "query" field. An
        // empty/whitespace-only value (`- launch:` or `{query: ""}`) is a
        // mistake, not a valid empty argument — reject it loudly (A19).
        if let s = value.stringValue {
            guard !isBlank(s) else {
                throw ScenarioParseError(message: "'\(key)' requires a non-empty value", line: nil)
            }
            return substitute(s, variables: variables)
        }
        if let q = value["query"]?.stringValue {
            guard !isBlank(q) else {
                throw ScenarioParseError(message: "'\(key)' requires a non-empty value", line: nil)
            }
            return substitute(q, variables: variables)
        }
        throw ScenarioParseError(message: "'\(key)' requires a string value", line: nil)
    }

    private static func requireField(_ value: YAMLValue, _ field: String,
                                      variables: [String: String],
                                      allowEmpty: Bool = false) throws -> String {
        guard let s = value[field]?.stringValue else {
            throw ScenarioParseError(message: "missing required field '\(field)'", line: nil)
        }
        if !allowEmpty && isBlank(s) {
            throw ScenarioParseError(message: "required field '\(field)' must not be empty", line: nil)
        }
        return substitute(s, variables: variables)
    }

    /// The bare-scalar form of an action (`tap: General`). Returns nil when the
    /// value is a mapping (caller uses the field form) OR an empty/whitespace
    /// scalar (`- tap:`) — so an empty value surfaces the field form's
    /// required-value error instead of silently posting an empty query (A19).
    private static func shorthandScalar(_ value: YAMLValue) -> String? {
        guard let s = value.stringValue, !isBlank(s) else { return nil }
        return s
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
