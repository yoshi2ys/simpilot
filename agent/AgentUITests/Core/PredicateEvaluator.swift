import Foundation

/// Evaluates predicates against a resolved element.
/// Used by ElementPoller for both `tap --wait-until` and `assert` flows.
enum Predicate: Equatable {
    case exists
    case notExists
    case enabled
    case value(expected: String)
    case label(expected: String)

    /// Short human-readable name used in error payloads (`failed_predicates`).
    var name: String {
        switch self {
        case .exists: return "exists"
        case .notExists: return "not-exists"
        case .enabled: return "enabled"
        case .value(let v): return "value=\(v)"
        case .label(let v): return "label=\(v)"
        }
    }

    /// Parse a flag-style predicate name from the `wait_until` array.
    /// Used by TapHandler to decode `["exists","enabled"]` into `[Predicate]`.
    /// Returns nil for unknown names or predicates that require an argument (value/label).
    /// For the full predicate set including value/label, see `AssertHandler.buildPredicate`.
    static func parseSimple(_ raw: String) -> Predicate? {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "exists": return .exists
        case "not-exists", "notexists", "gone": return .notExists
        case "enabled": return .enabled
        default: return nil
        }
    }
}

enum PredicateEvaluator {
    /// Evaluate a predicate against an observed element.
    /// - Parameters:
    ///   - predicate: the condition to check
    ///   - element: the currently-observed element, or nil if no element matched the query
    /// - Returns: true if the predicate holds for the observation
    static func matches(_ predicate: Predicate, element: DebugDescriptionParser.FoundElement?) -> Bool {
        switch predicate {
        case .exists:
            return element != nil
        case .notExists:
            return element == nil
        case .enabled:
            return element?.enabled == true
        case .value(let expected):
            return matchString(expected: expected, observed: element?.value)
        case .label(let expected):
            return matchString(expected: expected, observed: element?.label)
        }
    }

    private static func matchString(expected: String, observed: String?) -> Bool {
        guard let observed else { return false }
        // Trim both sides to absorb debugDescription whitespace noise
        // while keeping case and intermediate spaces significant.
        let e = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        let o = observed.trimmingCharacters(in: .whitespacesAndNewlines)
        return o == e
    }
}
