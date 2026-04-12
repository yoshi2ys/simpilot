import Foundation

// MARK: - Error

struct YAMLParseError: Error, CustomStringConvertible {
    let message: String
    let line: Int

    var description: String { "YAML parse error at line \(line): \(message)" }
}

// MARK: - AST

enum YAMLValue: Equatable, Sendable {
    case scalar(String)
    case sequence([YAMLValue])
    case mapping([(String, YAMLValue)])

    // Equatable for mapping (ordered pairs)
    static func == (lhs: YAMLValue, rhs: YAMLValue) -> Bool {
        switch (lhs, rhs) {
        case (.scalar(let a), .scalar(let b)):
            return a == b
        case (.sequence(let a), .sequence(let b)):
            return a == b
        case (.mapping(let a), .mapping(let b)):
            guard a.count == b.count else { return false }
            return zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default:
            return false
        }
    }

    // MARK: - Convenience accessors

    var stringValue: String? {
        if case .scalar(let s) = self { return s }
        return nil
    }

    var sequenceValue: [YAMLValue]? {
        if case .sequence(let s) = self { return s }
        return nil
    }

    var mappingValue: [(String, YAMLValue)]? {
        if case .mapping(let m) = self { return m }
        return nil
    }

    /// Dictionary-style lookup on a mapping. Returns the value for the first
    /// matching key, or nil if this is not a mapping or the key is absent.
    subscript(_ key: String) -> YAMLValue? {
        guard case .mapping(let pairs) = self else { return nil }
        return pairs.first(where: { $0.0 == key })?.1
    }
}

// MARK: - Parser

enum YAMLParser {

    /// Parse a YAML string into a `YAMLValue`. Only the block subset is
    /// supported: block mappings, block sequences, plain/quoted scalars,
    /// `#` comments. No anchors, tags, flow syntax, or multi-line scalars.
    static func parse(_ text: String) throws -> YAMLValue {
        var lines = tokenize(text)
        guard !lines.isEmpty else {
            return .mapping([])
        }
        let result = try parseNode(lines: &lines, minIndent: 0)
        if let stray = lines.first {
            throw YAMLParseError(
                message: "unexpected content after root node: '\(stray.content)'",
                line: stray.number
            )
        }
        return result
    }

    // MARK: - Tokenizer

    struct Line {
        let number: Int      // 1-based
        let indent: Int
        let content: String  // trimmed, comments stripped
    }

    /// Split source into meaningful lines (skip blanks and pure-comment lines).
    private static func tokenize(_ text: String) -> [Line] {
        var result: [Line] = []
        for (i, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNum = i + 1
            let stripped = stripComment(String(raw))
            let trimmed = stripped.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let indent = stripped.prefix(while: { $0 == " " }).count
            result.append(Line(number: lineNum, indent: indent, content: trimmed))
        }
        return result
    }

    /// Remove inline `#` comments that are preceded by whitespace.
    /// Respects single and double quoted strings — a `#` inside quotes is kept.
    private static func stripComment(_ line: String) -> String {
        var inSingle = false
        var inDouble = false
        var escaped = false
        var prev: Character = "\0"
        var endIndex = line.endIndex
        for i in line.indices {
            let ch = line[i]
            if escaped {
                escaped = false
                prev = ch
                continue
            }
            if inDouble && ch == "\\" {
                escaped = true
                prev = ch
                continue
            }
            if ch == "'" && !inDouble { inSingle.toggle() }
            else if ch == "\"" && !inSingle { inDouble.toggle() }
            else if ch == "#" && !inSingle && !inDouble && (prev == " " || prev == "\t" || i == line.startIndex) {
                endIndex = i
                break
            }
            prev = ch
        }
        return String(line[..<endIndex])
    }

    // MARK: - Recursive descent

    private static func parseNode(lines: inout [Line], minIndent: Int) throws -> YAMLValue {
        guard let first = lines.first, first.indent >= minIndent else {
            return .scalar("")
        }

        // Sequence?
        if first.content.hasPrefix("- ") || first.content == "-" {
            return try parseSequence(lines: &lines, seqIndent: first.indent)
        }

        // Mapping?
        if isMappingLine(first.content) {
            return try parseMapping(lines: &lines, mapIndent: first.indent)
        }

        // Scalar
        lines.removeFirst()
        return .scalar(unquote(first.content))
    }

    // MARK: - Mapping

    private static func isMappingLine(_ content: String) -> Bool {
        // "key:" or "key: value"
        guard let colonIdx = findUnquotedColon(content) else { return false }
        let afterColon = content.index(after: colonIdx)
        return afterColon == content.endIndex || content[afterColon] == " "
    }

    /// Find the first `:` not inside quotes, followed by end-of-string or space.
    private static func findUnquotedColon(_ s: String) -> String.Index? {
        var inSingle = false
        var inDouble = false
        for i in s.indices {
            let ch = s[i]
            if ch == "'" && !inDouble { inSingle.toggle() }
            else if ch == "\"" && !inSingle { inDouble.toggle() }
            else if ch == ":" && !inSingle && !inDouble {
                let next = s.index(after: i)
                if next == s.endIndex || s[next] == " " {
                    return i
                }
            }
        }
        return nil
    }

    private static func parseMapping(lines: inout [Line], mapIndent: Int) throws -> YAMLValue {
        var pairs: [(String, YAMLValue)] = []

        while let line = lines.first, line.indent == mapIndent, isMappingLine(line.content) {
            guard let colonIdx = findUnquotedColon(line.content) else {
                throw YAMLParseError(message: "expected mapping key", line: line.number)
            }
            let key = unquote(String(line.content[..<colonIdx]).trimmingCharacters(in: .whitespaces))
            let afterColon = line.content.index(after: colonIdx)
            let rest = afterColon < line.content.endIndex
                ? String(line.content[afterColon...]).trimmingCharacters(in: .whitespaces)
                : ""

            lines.removeFirst()

            if !rest.isEmpty {
                // Inline scalar value: `key: value`
                pairs.append((key, .scalar(unquote(rest))))
            } else {
                // Block child — must be indented further
                if let next = lines.first, next.indent > mapIndent {
                    let child = try parseNode(lines: &lines, minIndent: next.indent)
                    pairs.append((key, child))
                } else {
                    // Empty value: `key:` with nothing below
                    pairs.append((key, .scalar("")))
                }
            }
        }

        return .mapping(pairs)
    }

    // MARK: - Sequence

    private static func parseSequence(lines: inout [Line], seqIndent: Int) throws -> YAMLValue {
        var items: [YAMLValue] = []

        while let line = lines.first, line.indent == seqIndent,
              (line.content.hasPrefix("- ") || line.content == "-") {

            let after: String
            if line.content == "-" {
                after = ""
            } else {
                after = String(line.content.dropFirst(2))
            }
            let lineNumber = line.number
            lines.removeFirst()

            if after.isEmpty {
                // Block child under the `- `
                if let next = lines.first, next.indent > seqIndent {
                    let child = try parseNode(lines: &lines, minIndent: next.indent)
                    items.append(child)
                } else {
                    items.append(.scalar(""))
                }
            } else if isMappingLine(after) {
                // `- key: value` — inline mapping start
                // Re-inject as a virtual line at indent = seqIndent + 2 so the
                // mapping parser picks it up along with any continuation lines.
                let virtualIndent = seqIndent + 2
                let virtual = Line(number: lineNumber, indent: virtualIndent, content: after)
                lines.insert(virtual, at: 0)
                let child = try parseNode(lines: &lines, minIndent: virtualIndent)
                items.append(child)
            } else {
                items.append(.scalar(unquote(after)))
            }
        }

        return .sequence(items)
    }

    // MARK: - Helpers

    private static func unquote(_ s: String) -> String {
        if s.count >= 2 {
            if (s.hasPrefix("\"") && s.hasSuffix("\"")) ||
               (s.hasPrefix("'") && s.hasSuffix("'")) {
                return String(s.dropFirst().dropLast())
            }
        }
        return s
    }
}
