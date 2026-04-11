import XCTest
@testable import simpilot

/// Drift backstop: every flag declared in a command's `argSpec` must also
/// appear in its `synopsis` string. Flag-name matching uses a negative
/// lookahead for `[a-zA-Z0-9-]` so `--app` does not false-match `--apple`.
final class ArgSpecHelpSyncTests: XCTestCase {

    /// Pins `Simpilot.assertRegistryInvariants`'s contract at the test level.
    /// Even if the runtime precondition is ever loosened or removed, this
    /// test still catches duplicate command names in CI. Fail-fast precondition
    /// in production + test pin in CI = dual-layer defense against silent
    /// `registry.first(where:)` shadowing.
    func testRegistryCommandNamesAreUnique() {
        let names = Simpilot.registry.map { $0.name }
        XCTAssertEqual(
            Set(names).count,
            names.count,
            "Simpilot.registry contains duplicate command names: \(names)"
        )
    }

    func testEveryRegistryCommandHasConsistentSpecAndSynopsis() {
        for cmdType in Simpilot.registry {
            let synopsis = cmdType.synopsis
            for flag in cmdType.argSpec.flags {
                XCTAssertTrue(
                    synopsisContainsFlag(synopsis: synopsis, flagName: flag.name),
                    """
                    \(cmdType.name) synopsis is missing flag '\(flag.name)' \
                    (or only has a prefix match that would false-negative at a word boundary).
                      synopsis: \(synopsis)
                      argSpec flags: \(cmdType.argSpec.flags.map { $0.name }.sorted())
                    """
                )
            }
        }
    }

    // MARK: - Word-boundary helper + its own tests

    /// True iff `flagName` appears in `synopsis` NOT immediately followed by
    /// `[a-zA-Z0-9-]` — which would indicate a prefix collision (e.g. `--app`
    /// matching `--apple`). Uses negative-lookahead regex.
    private func synopsisContainsFlag(synopsis: String, flagName: String) -> Bool {
        let pattern = NSRegularExpression.escapedPattern(for: flagName) + "(?![a-zA-Z0-9-])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(synopsis.startIndex..., in: synopsis)
        return regex.firstMatch(in: synopsis, options: [], range: range) != nil
    }

    func testSynopsisMatchHonorsWordBoundary() {
        // Positive cases: flag followed by space / bracket / paren / pipe / EOS.
        XCTAssertTrue(synopsisContainsFlag(synopsis: "source [--app <bundleId>]", flagName: "--app"))
        XCTAssertTrue(synopsisContainsFlag(synopsis: "stop (--port <p> | --all)", flagName: "--port"))
        XCTAssertTrue(synopsisContainsFlag(synopsis: "... | --all)", flagName: "--all"))
        XCTAssertTrue(synopsisContainsFlag(synopsis: "wait <q> [--gone]", flagName: "--gone"))
        XCTAssertTrue(synopsisContainsFlag(synopsis: "--all", flagName: "--all")) // EOS

        // Negative cases: prefix of a longer flag name.
        XCTAssertFalse(synopsisContainsFlag(synopsis: "--apple", flagName: "--app"))
        XCTAssertFalse(synopsisContainsFlag(synopsis: "[--port-override <n>]", flagName: "--port"))
        XCTAssertFalse(synopsisContainsFlag(synopsis: "--gone2", flagName: "--gone"))
    }
}
