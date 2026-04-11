import Foundation

/// String comparison strategy used by `label` / `value` predicates.
/// Parsed once from the raw expected string so the regex is compiled at
/// build time, not every poll tick.
enum StringMatcher {
    /// Trimmed exact match, case-sensitive, internal whitespace preserved.
    case exact(String)
    /// Case-insensitive substring match against the folded (trimmed +
    /// whitespace-collapsed) observed value. Folding includes NBSP so UI
    /// strings like "42\u{00A0}%" match `contains:42 %`.
    case contains(folded: String)
    /// User-compiled regex, evaluated via NSRegularExpression.firstMatch
    /// against the trimmed observed value.
    case regex(NSRegularExpression)

    /// Human-readable form used in `Predicate.name` and failure payloads.
    var debugDescription: String {
        switch self {
        case .exact(let s): return s
        case .contains(let s): return "contains:\(s)"
        case .regex(let r): return "regex:\(r.pattern)"
        }
    }

    /// Parse an `expected` argument into a matcher. Prefix rules:
    ///   - "contains:<substr>" → `.contains` (empty substring rejected)
    ///   - "regex:<pattern>"   → `.regex` (invalid pattern rejected)
    ///   - anything else       → `.exact` (trimmed)
    static func parse(_ raw: String) -> Result<StringMatcher, ParseError> {
        if let substr = raw.stripPrefix("contains:") {
            let folded = foldWhitespace(substr)
            if folded.isEmpty {
                return .failure(.emptyContains)
            }
            return .success(.contains(folded: folded))
        }
        if let pattern = raw.stripPrefix("regex:") {
            do {
                return .success(.regex(try NSRegularExpression(pattern: pattern, options: [])))
            } catch {
                return .failure(.invalidRegex(pattern: pattern, reason: error.localizedDescription))
            }
        }
        return .success(.exact(raw.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    enum ParseError: Error {
        case emptyContains
        case invalidRegex(pattern: String, reason: String)
    }

    /// Trim both ends, then collapse every run of Unicode whitespace (including
    /// NBSP) into a single ASCII space, and lowercase. Used for `contains`
    /// folding on both expected and observed values so case and spacing noise
    /// don't break assertions against dynamic UI strings.
    static func foldWhitespace(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = ""
        result.reserveCapacity(trimmed.count)
        var lastWasSpace = false
        for scalar in trimmed.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !lastWasSpace {
                    result.append(" ")
                    lastWasSpace = true
                }
            } else {
                result.unicodeScalars.append(scalar)
                lastWasSpace = false
            }
        }
        return result.lowercased()
    }

    func matches(_ observed: String?) -> Bool {
        guard let observed else { return false }
        switch self {
        case .exact(let expected):
            return observed.trimmingCharacters(in: .whitespacesAndNewlines) == expected
        case .contains(let folded):
            return StringMatcher.foldWhitespace(observed).contains(folded)
        case .regex(let regex):
            let target = observed.trimmingCharacters(in: .whitespacesAndNewlines)
            let range = NSRange(target.startIndex..<target.endIndex, in: target)
            return regex.firstMatch(in: target, options: [], range: range) != nil
        }
    }
}

extension StringMatcher: Equatable {
    // NSRegularExpression inherits NSObject.== (pointer identity), which would
    // report two regexes compiled from the same pattern as unequal. Compare by
    // pattern string so Predicate equality reflects caller intent.
    static func == (lhs: StringMatcher, rhs: StringMatcher) -> Bool {
        switch (lhs, rhs) {
        case (.exact(let a), .exact(let b)): return a == b
        case (.contains(let a), .contains(let b)): return a == b
        case (.regex(let a), .regex(let b)): return a.pattern == b.pattern
        default: return false
        }
    }
}

private extension String {
    func stripPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}

/// Evaluates predicates against a resolved element.
/// Used by ElementPoller for both `tap --wait-until` and `assert` flows.
enum Predicate: Equatable {
    case exists
    case notExists
    case enabled
    case hittable
    case value(StringMatcher)
    case label(StringMatcher)

    /// Short human-readable name used in error payloads (`failed_predicates`).
    var name: String {
        switch self {
        case .exists: return "exists"
        case .notExists: return "not-exists"
        case .enabled: return "enabled"
        case .hittable: return "hittable"
        case .value(let m): return "value=\(m.debugDescription)"
        case .label(let m): return "label=\(m.debugDescription)"
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
        case "hittable": return .hittable
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
        case .hittable:
            return element?.hittable == true
        case .value(let matcher):
            return matcher.matches(element?.value)
        case .label(let matcher):
            return matcher.matches(element?.label)
        }
    }
}
