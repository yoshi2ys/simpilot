import XCTest
@testable import simpilot

/// Drift backstop: typed query prefixes must be consistent across
/// HelpCommands (user-facing docs) and ElementResolver (agent runtime).
/// Data-driven — add a row to `allTypedPrefixes` whenever a new prefix
/// lands, and both the doc and resolver checks light up automatically.
final class QuerySyntaxSyncTests: XCTestCase {

    // MARK: - Ground truth

    /// Every typed prefix that simpilot supports.
    /// Adding a prefix here without updating both HelpCommands and
    /// ElementResolver will fail the corresponding test.
    static let allTypedPrefixes: [String] = [
        // Original
        "button", "text", "textField", "secureTextField", "searchField",
        "switch", "cell", "image", "nav", "tab", "alert", "link",
        // Wave 5a
        "icon", "toggle", "slider", "stepper", "picker",
        "segmentedControl", "menu", "menuItem", "scrollView",
        "webView", "datePicker", "textView",
    ]

    // MARK: - Data-driven prefix acceptance

    /// Every typed prefix must appear in HelpCommands.queryFormats.
    func testAllPrefixesDocumentedInHelpCommands() {
        let documented = Self.helpCommandPrefixes
        for prefix in Self.allTypedPrefixes {
            XCTAssertTrue(
                documented.contains(prefix),
                "Prefix '\(prefix)' missing from HelpCommands.queryFormats"
            )
        }
    }

    /// Every typed prefix must have a `case` in ElementResolver.swift.
    func testAllPrefixesHandledInElementResolver() throws {
        let source = try Self.loadElementResolverSource()
        for prefix in Self.allTypedPrefixes {
            XCTAssertTrue(
                source.contains("case \"\(prefix)\":"),
                "Prefix '\(prefix)' missing from ElementResolver switch statement"
            )
        }
    }

    // MARK: - Bidirectional sync

    /// No HelpCommands prefix undocumented in ElementResolver, and vice versa.
    func testHelpCommandsAndElementResolverInSync() throws {
        let resolverPrefixes = try Self.elementResolverPrefixes()
        let helpPrefixes = Self.helpCommandPrefixes

        let missingInResolver = helpPrefixes.subtracting(resolverPrefixes)
        let missingInHelp = resolverPrefixes.subtracting(helpPrefixes)

        XCTAssertTrue(
            missingInResolver.isEmpty,
            "HelpCommands documents prefixes not handled by ElementResolver: \(missingInResolver.sorted())"
        )
        XCTAssertTrue(
            missingInHelp.isEmpty,
            "ElementResolver handles prefixes not documented in HelpCommands: \(missingInHelp.sorted())"
        )
    }

    // MARK: - toggle: correctness

    /// toggle: must resolve via app.toggles (SwiftUI Toggle),
    /// NOT app.switches (UIKit UISwitch).
    func testTogglePrefixUsesTogglesNotSwitches() throws {
        let source = try Self.loadElementResolverSource()
        guard let caseStart = source.range(of: "case \"toggle\":") else {
            XCTFail("ElementResolver missing toggle case")
            return
        }
        let afterCase = String(source[caseStart.upperBound...])
        let nextCase = afterCase.range(of: "\n            case ")?.lowerBound
            ?? afterCase.range(of: "\n            default:")?.lowerBound
            ?? afterCase.endIndex
        let toggleBlock = String(afterCase[..<nextCase])

        XCTAssertTrue(
            toggleBlock.contains("app.toggles"),
            "toggle: must use app.toggles — SwiftUI Toggle is a distinct element type from UIKit UISwitch"
        )
        XCTAssertFalse(
            toggleBlock.contains("app.switches"),
            "toggle: must NOT use app.switches — that only matches UIKit UISwitch"
        )
    }

    // MARK: - Helpers

    private static var helpCommandPrefixes: Set<String> {
        Set(
            HelpCommands.queryFormats.compactMap { fmt -> String? in
                guard let colon = fmt.pattern.firstIndex(of: ":") else { return nil }
                return String(fmt.pattern[..<colon])
            }
        )
    }

    private static func elementResolverPrefixes() throws -> Set<String> {
        let source = try loadElementResolverSource()
        let regex = try NSRegularExpression(pattern: #"case "(\w+)":"#)
        let range = NSRange(source.startIndex..., in: source)
        return Set(
            regex.matches(in: source, range: range).compactMap { match -> String? in
                guard let r = Range(match.range(at: 1), in: source) else { return nil }
                return String(source[r])
            }
        )
    }

    private static func loadElementResolverSource() throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        var dir = thisFile.deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir
                .appendingPathComponent("agent")
                .appendingPathComponent("AgentUITests")
                .appendingPathComponent("Core")
                .appendingPathComponent("ElementResolver.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            dir = dir.deletingLastPathComponent()
        }
        throw NSError(
            domain: "QuerySyntaxSyncTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not locate ElementResolver.swift from \(#filePath)"]
        )
    }
}
