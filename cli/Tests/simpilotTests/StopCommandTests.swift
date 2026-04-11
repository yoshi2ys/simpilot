import XCTest
@testable import simpilot

/// Tests `StopCommand`'s pure parse + resolve helpers. These replace the
/// Wave 2.1 synthetic stop-spec tests that were marked parser-contract-only
/// (Reviewer #3b deferred item) with real live-CLI coverage.
///
/// The integration-level "does `stopAllAgents` actually kill processes?" path
/// is intentionally NOT unit-tested here — it mutates the real `~/.simpilot`
/// directory and sends SIGTERM to real PIDs, which belongs in a smoke test,
/// not an xctest. The boundary we verify in this file:
///
/// - `parseStopTarget` applies (D) no-target and `--all` exclusivity rules
/// - `resolveSingle` applies (F) --port/--udid consistency rules against a
///   synthetic registry snapshot
final class StopCommandTests: XCTestCase {

    // MARK: - parseStopTarget (args → intent)

    func testNoArgsThrowsWithHelpfulMessage() {
        XCTAssertThrowsError(try StopCommand.parseStopTarget(args: [])) { error in
            assertInvalidArgs(error, contains: "no target specified")
            assertInvalidArgs(error, contains: "--port")
            assertInvalidArgs(error, contains: "--udid")
            assertInvalidArgs(error, contains: "--all")
        }
    }

    func testPortFlagResolvesToPortTarget() throws {
        let target = try StopCommand.parseStopTarget(args: ["--port", "8223"])
        XCTAssertEqual(target, .port(8223))
    }

    func testUdidFlagResolvesToUdidTarget() throws {
        let target = try StopCommand.parseStopTarget(args: ["--udid", "ABC-123"])
        XCTAssertEqual(target, .udid("ABC-123"))
    }

    func testAllFlagResolvesToAllTarget() throws {
        let target = try StopCommand.parseStopTarget(args: ["--all"])
        XCTAssertEqual(target, .all)
    }

    func testPortAndUdidResolvesToCombinedTarget() throws {
        let target = try StopCommand.parseStopTarget(args: ["--port", "8223", "--udid", "ABC"])
        XCTAssertEqual(target, .portAndUdid(8223, "ABC"))
    }

    func testAllWithPortIsRejected() {
        XCTAssertThrowsError(try StopCommand.parseStopTarget(args: ["--all", "--port", "8222"])) { error in
            assertInvalidArgs(error, contains: "--all")
            assertInvalidArgs(error, contains: "--port")
        }
    }

    func testAllWithUdidIsRejected() {
        XCTAssertThrowsError(try StopCommand.parseStopTarget(args: ["--all", "--udid", "XYZ"])) { error in
            assertInvalidArgs(error, contains: "--all")
            assertInvalidArgs(error, contains: "--udid")
        }
    }

    func testUnknownFlagRejected() {
        XCTAssertThrowsError(try StopCommand.parseStopTarget(args: ["--force"])) { error in
            assertInvalidArgs(error, contains: "--force")
            assertInvalidArgs(error, contains: "stop")
        }
    }

    func testExtraPositionalRejected() {
        XCTAssertThrowsError(try StopCommand.parseStopTarget(args: ["foo"])) { error in
            assertInvalidArgs(error, contains: "unexpected argument")
        }
    }

    func testInvalidPortValueRejected() {
        XCTAssertThrowsError(try StopCommand.parseStopTarget(args: ["--port", "eight"])) { error in
            assertInvalidArgs(error, contains: "--port")
            assertInvalidArgs(error, contains: "integer")
        }
    }

    // MARK: - resolveSingle (intent + snapshot → record or error)

    func testResolvePortMatchingRecord() throws {
        let records = [rec(port: 8222, udid: "A"), rec(port: 8223, udid: "B")]
        let match = try StopCommand.resolveSingle(target: .port(8223), in: records)
        XCTAssertEqual(match?.port, 8223)
        XCTAssertEqual(match?.udid, "B")
    }

    func testResolvePortMissingReturnsNil() throws {
        let records = [rec(port: 8222, udid: "A")]
        let match = try StopCommand.resolveSingle(target: .port(9999), in: records)
        XCTAssertNil(match, "Missing single-target is idempotent 'already stopped', not an error")
    }

    func testResolveUdidMatchingRecord() throws {
        let records = [rec(port: 8222, udid: "A"), rec(port: 8223, udid: "B")]
        let match = try StopCommand.resolveSingle(target: .udid("A"), in: records)
        XCTAssertEqual(match?.port, 8222)
    }

    func testResolveUdidMissingReturnsNil() throws {
        let records = [rec(port: 8222, udid: "A")]
        let match = try StopCommand.resolveSingle(target: .udid("Z"), in: records)
        XCTAssertNil(match)
    }

    func testResolvePortAndUdidMatchingSameRecord() throws {
        let records = [rec(port: 8222, udid: "A"), rec(port: 8223, udid: "B")]
        let match = try StopCommand.resolveSingle(target: .portAndUdid(8223, "B"), in: records)
        XCTAssertEqual(match?.port, 8223)
        XCTAssertEqual(match?.udid, "B")
    }

    func testResolvePortAndUdidInconsistencyThrows() {
        // All three inconsistency shapes land on the same reject branch:
        //   - both registered but to different records (swap)
        //   - one side missing (partial claim)
        //   - neither side registered (bad claim)
        // Table-driven so regressions in any shape show up as a failing row.
        let registry = [rec(port: 8222, udid: "A"), rec(port: 8223, udid: "B")]
        let cases: [(label: String, records: [AgentRecord], target: StopCommand.StopTarget)] = [
            ("swap",          registry, .portAndUdid(8223, "A")),
            ("port-only",     [rec(port: 8222, udid: "A")], .portAndUdid(8222, "B")),
            ("udid-only",     [rec(port: 8222, udid: "A")], .portAndUdid(9999, "A")),
            ("neither-exist", [],       .portAndUdid(9999, "Z")),
        ]

        for c in cases {
            XCTAssertThrowsError(
                try StopCommand.resolveSingle(target: c.target, in: c.records),
                "case '\(c.label)' should throw"
            ) { error in
                assertInvalidArgs(error, contains: "different agents")
            }
        }
    }

    // MARK: - Global --port propagation (#1 fix)

    func testGlobalPortExplicitWithNoLocalTargetForwardsAsPort() throws {
        let target = try StopCommand.parseStopTarget(
            args: [],
            globalPort: 8223,
            portExplicit: true
        )
        XCTAssertEqual(target, .port(8223))
    }

    func testGlobalPortExplicitMatchingLocalPortIsOk() throws {
        let target = try StopCommand.parseStopTarget(
            args: ["--port", "8223"],
            globalPort: 8223,
            portExplicit: true
        )
        XCTAssertEqual(target, .port(8223))
    }

    func testGlobalPortExplicitConflictingLocalPortThrows() {
        XCTAssertThrowsError(
            try StopCommand.parseStopTarget(
                args: ["--port", "8224"],
                globalPort: 8223,
                portExplicit: true
            )
        ) { error in
            assertInvalidArgs(error, contains: "global --port 8223")
            assertInvalidArgs(error, contains: "local --port 8224")
            assertInvalidArgs(error, contains: "conflicts")
        }
    }

    func testGlobalPortExplicitWithLocalUdidUpgradesToPortAndUdid() throws {
        // global --port + local --udid → consistency check via .portAndUdid
        let target = try StopCommand.parseStopTarget(
            args: ["--udid", "ABC"],
            globalPort: 8223,
            portExplicit: true
        )
        XCTAssertEqual(target, .portAndUdid(8223, "ABC"))
    }

    func testGlobalPortExplicitWithAllThrows() {
        // --all is holistic; explicit global --port is single-target. Conflict.
        XCTAssertThrowsError(
            try StopCommand.parseStopTarget(
                args: ["--all"],
                globalPort: 8223,
                portExplicit: true
            )
        ) { error in
            assertInvalidArgs(error, contains: "--all")
            assertInvalidArgs(error, contains: "global --port 8223")
        }
    }

    func testGlobalPortNotExplicitDefaultDoesNotForward() {
        // Default 8222 must NOT be forwarded — would silently target an agent.
        XCTAssertThrowsError(
            try StopCommand.parseStopTarget(
                args: [],
                globalPort: 8222,
                portExplicit: false
            )
        ) { error in
            assertInvalidArgs(error, contains: "no target specified")
        }
    }

    // MARK: - Orphan detection (#2 fix)

    func testDetectOrphansFiltersKnownPIDs() {
        let pgrep = "123\n456\n789\n"
        let orphans = StopCommand.detectOrphans(
            pgrepOutput: pgrep,
            excluding: [456]
        )
        XCTAssertEqual(orphans.sorted(), [123, 789])
    }

    func testDetectOrphansEmptyInput() {
        XCTAssertEqual(
            StopCommand.detectOrphans(pgrepOutput: "", excluding: []),
            []
        )
    }

    func testDetectOrphansAllKnown() {
        let pgrep = "100\n200\n"
        XCTAssertEqual(
            StopCommand.detectOrphans(pgrepOutput: pgrep, excluding: [100, 200]),
            []
        )
    }

    func testDetectOrphansIgnoresNonNumericLines() {
        let pgrep = "123\ngarbage\n456\n\n"
        XCTAssertEqual(
            StopCommand.detectOrphans(pgrepOutput: pgrep, excluding: []).sorted(),
            [123, 456]
        )
    }

    func testDetectOrphansHandlesCRLF() {
        let pgrep = "111\r\n222\r\n"
        XCTAssertEqual(
            StopCommand.detectOrphans(pgrepOutput: pgrep, excluding: []).sorted(),
            [111, 222]
        )
    }

    func testDetectOrphansTrimsWhitespace() {
        let pgrep = "  500  \n  600\n"
        XCTAssertEqual(
            StopCommand.detectOrphans(pgrepOutput: pgrep, excluding: []).sorted(),
            [500, 600]
        )
    }

    // MARK: - pgrep pattern ownership (Wave 2.2 Reviewer #4 fix)

    /// Pins `orphanPgrepPattern` to the simpilot-specific shape. A bare
    /// `AgentUITests` pattern would match any repo that shares the scheme name;
    /// the combined `AgentApp.xcodeproj.*AgentUITests` pattern is what Reviewer
    /// #4 required to bound the cleanup to simpilot-owned runners. If a future
    /// change loosens the pattern, this test is the tripwire.
    func testOrphanPgrepPatternIsSimpilotSpecific() throws {
        // 1. Pattern string is stable.
        XCTAssertEqual(
            StopCommand.orphanPgrepPattern,
            #"AgentApp\.xcodeproj.*AgentUITests"#
        )

        // 2. Pattern matches a representative simpilot xcodebuild argv…
        let simpilotArgv = "/usr/bin/xcodebuild test -project /Users/y/simpilot/agent/AgentApp.xcodeproj -scheme AgentUITests -destination platform=iOS Simulator,name=iPhone 17 Pro -only-testing:AgentUITests -parallel-testing-enabled NO"
        XCTAssertTrue(regexMatches(StopCommand.orphanPgrepPattern, in: simpilotArgv),
                      "Pattern must match simpilot's own xcodebuild argv")

        // 3. …and does NOT match an unrelated project's UI test runner that
        // happens to share the scheme name "AgentUITests".
        let otherArgv = "/usr/bin/xcodebuild test -project /Users/y/other/Other.xcodeproj -scheme AgentUITests -destination platform=iOS Simulator,name=iPhone 17 Pro"
        XCTAssertFalse(regexMatches(StopCommand.orphanPgrepPattern, in: otherArgv),
                       "Pattern must NOT match other repos that reuse the AgentUITests scheme name")

        // 4. …and does NOT match a generic xcodebuild invocation.
        let unrelatedArgv = "/usr/bin/xcodebuild test -project /Users/y/app/MyApp.xcodeproj -scheme MyUITests"
        XCTAssertFalse(regexMatches(StopCommand.orphanPgrepPattern, in: unrelatedArgv))
    }

    private func regexMatches(_ pattern: String, in string: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return regex.firstMatch(in: string, options: [], range: range) != nil
    }

    // MARK: - Helpers

    private func rec(port: Int, udid: String) -> AgentRecord {
        AgentRecord(
            port: port,
            pid: 0,
            udid: udid,
            device: "Test",
            isClone: false,
            startedAt: Date()
        )
    }

    private func assertInvalidArgs(
        _ error: Error,
        contains needle: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case CLIError.invalidArgs(let msg) = error else {
            XCTFail("Expected CLIError.invalidArgs, got \(error)", file: file, line: line)
            return
        }
        XCTAssertTrue(
            msg.contains(needle),
            "Expected error message to contain '\(needle)', got: \(msg)",
            file: file,
            line: line
        )
    }
}
