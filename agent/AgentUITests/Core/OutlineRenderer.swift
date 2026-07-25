import Foundation

/// Renders an actionable element list as one text line per element.
///
/// The JSON element list spends most of its bytes on key names and frames that
/// an LLM never reads — a caller that resolves elements by alias does not need
/// coordinates, because the alias is resolved agent-side. Measured on the iOS
/// Settings root (iPhone 17 Pro, 45 elements): 1,200 bytes against 7,184 for the
/// same list as `level=1` JSON.
///
/// Line shape (the skeleton is agent-browser / Playwright's aria snapshot, so
/// output an LLM has seen before parses the same way):
///
///     - button "General" @e9
///     - switch "Wi-Fi" @e11 [value=1]
///     - button "Bluetooth" @e12 [disabled]
///     - cell @e13
///
/// Deliberately absent: frames, column alignment, and tree indentation. Aligning
/// columns would cost a whitespace run per line *and* shift every line whenever
/// one long label appears, which defeats diffing two snapshots byte-for-byte.
enum OutlineRenderer {

    /// One rendered line paired with the element it came from, so the alias
    /// numbering and the element identity have a single source (SU3's cache is
    /// populated from this, never from a second parse — a re-numbered list would
    /// silently point aliases at the wrong elements).
    struct Entry {
        let alias: String
        let element: [String: Any]
    }

    struct Rendered {
        let text: String
        let entries: [Entry]
    }

    /// Render the output of `parseActionableList` (after `ElementsHandler.applyFilters`).
    /// Aliases are numbered over the *rendered* lines, 1-based.
    static func render(_ elements: [[String: Any]]) -> Rendered {
        var lines: [String] = []
        var entries: [Entry] = []
        lines.reserveCapacity(elements.count)
        entries.reserveCapacity(elements.count)

        for (index, element) in elements.enumerated() {
            let alias = "@e\(index + 1)"
            lines.append(line(for: element, alias: alias))
            entries.append(Entry(alias: alias, element: element))
        }
        return Rendered(text: lines.joined(separator: "\n"), entries: entries)
    }

    // MARK: - Line

    static func line(for element: [String: Any], alias: String) -> String {
        var parts = ["-", role(of: element)]
        if let name = name(of: element) {
            parts.append("\"\(escape(name, delimiter: "\""))\"")
        }
        parts.append(alias)
        if element["enabled"] as? Bool == false {
            parts.append("[disabled]")
        }
        if let value = element["value"] as? String, !value.isEmpty {
            parts.append("[value=\(escape(value, delimiter: "]"))]")
        }
        return parts.joined(separator: " ")
    }

    /// The element type verbatim — `normalizeTypeName`'s camelCase, not an ARIA
    /// role. Translating would force an invented name for every type ARIA has no
    /// word for, and lowercasing gives `searchfield`, which matches neither
    /// vocabulary nor the `--type` filter the caller would write next.
    private static func role(of element: [String: Any]) -> String {
        let type = element["type"] as? String ?? ""
        return type.isEmpty ? "unknown" : type
    }

    /// Label, else identifier, else nothing. An element whose name simpilot
    /// cannot know renders without the name slot rather than with `""`.
    private static func name(of element: [String: Any]) -> String? {
        if let label = element["label"] as? String, !label.isEmpty { return label }
        if let identifier = element["identifier"] as? String, !identifier.isEmpty { return identifier }
        return nil
    }

    /// Escapes the backslash and the slot's own closing delimiter, so a value
    /// cannot end its slot early. The delimiter is a parameter because the line
    /// has two slots that close differently — the name is `"…"`, an attribute is
    /// `[…]` — and escaping a quote inside `[value=…]` would only add bytes to
    /// a character that ends nothing there.
    ///
    /// Newlines and tabs collapse to a space in both: the format is line-based,
    /// so a literal newline would forge an extra element line.
    static func escape(_ raw: String, delimiter: Character) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        for character in raw {
            switch character {
            case "\\": out += "\\\\"
            case delimiter: out += "\\\(delimiter)"
            case "\n", "\r", "\t": out += " "
            default: out.append(character)
            }
        }
        return out
    }
}
