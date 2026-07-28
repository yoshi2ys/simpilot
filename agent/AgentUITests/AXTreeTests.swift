import XCTest

/// SU5: one `debugDescription` fetch may be shared across a batch's sub-commands,
/// and must be dropped the moment one of them can have changed the screen.
final class AXTreeTests: XCTestCase {

    override func tearDown() {
        // Caching is process state. A test that left a batch open would otherwise
        // hand its cached tree to the next one.
        AXTree.end()
        super.tearDown()
    }

    /// A fetch source that answers differently every time, so a reused answer is
    /// visible rather than merely plausible.
    private func counter() -> () -> String {
        var n = 0
        return { n += 1; return "tree-\(n)" }
    }

    // MARK: - The caching rule

    /// The default, and what `ax_cache: "none"` asks for: nothing about the pre-SU5
    /// behavior changes, every read is a fresh look at the screen.
    func test_off_everyReadFetches() {
        let fetch = counter()
        XCTAssertEqual(AXTree.read(fetch), "tree-1", "no batch has begun")

        AXTree.begin(mode: .off)
        XCTAssertEqual(AXTree.read(fetch), "tree-2")
        XCTAssertEqual(AXTree.read(fetch), "tree-3")
        XCTAssertEqual(AXTree.reads, 2)
        XCTAssertEqual(AXTree.fetches, 2)
    }

    func test_perBatch_reusesOneFetch() {
        AXTree.begin(mode: .perBatch)
        let fetch = counter()
        XCTAssertEqual(AXTree.read(fetch), "tree-1")
        XCTAssertEqual(AXTree.read(fetch), "tree-1")
        XCTAssertEqual(AXTree.read(fetch), "tree-1")
        XCTAssertEqual(AXTree.reads, 3)
        XCTAssertEqual(AXTree.fetches, 1, "the whole point: three reads, one IPC")
    }

    func test_perBatch_invalidateForcesTheNextReadToLookAgain() {
        AXTree.begin(mode: .perBatch)
        let fetch = counter()
        XCTAssertEqual(AXTree.read(fetch), "tree-1")
        AXTree.invalidate()
        XCTAssertEqual(AXTree.read(fetch), "tree-2")
        XCTAssertEqual(AXTree.read(fetch), "tree-2")
        XCTAssertEqual(AXTree.fetches, 2)
    }

    /// `settle` is how all three in-command sites say "the screen may differ after
    /// this wait, and I am about to read it", so the drop has to survive the wait.
    func test_settleWaitsAndThenDropsTheTree() {
        AXTree.begin(mode: .perBatch)
        let fetch = counter()
        XCTAssertEqual(AXTree.read(fetch), "tree-1")

        let start = Date()
        AXTree.settle(0.05)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.05)
        XCTAssertEqual(AXTree.read(fetch), "tree-2")
    }

    /// Batch B must never resolve against batch A's screen — an arbitrary amount of
    /// time and any number of non-batch commands sit between them.
    func test_beginDropsThePreviousBatchesTreeAndCounters() {
        AXTree.begin(mode: .perBatch)
        let first = counter()
        XCTAssertEqual(AXTree.read(first), "tree-1")

        AXTree.begin(mode: .perBatch)
        let second = counter()
        XCTAssertEqual(AXTree.read(second), "tree-1", "batch B fetched for itself")
        XCTAssertEqual(AXTree.reads, 1)
        XCTAssertEqual(AXTree.fetches, 1)
    }

    func test_endLeavesCachingOffAndKeepsNoTree() {
        AXTree.begin(mode: .perBatch)
        let fetch = counter()
        XCTAssertEqual(AXTree.read(fetch), "tree-1")
        AXTree.end()
        XCTAssertEqual(AXTree.mode, .off)
        XCTAssertEqual(AXTree.read(fetch), "tree-2")
        XCTAssertEqual(AXTree.read(fetch), "tree-3")
    }

    // MARK: - The `ax_cache` field

    func test_parse_absentOrNullIsOff() {
        XCTAssertEqual(AXTree.Mode.parse(nil), .off)
        XCTAssertEqual(AXTree.Mode.parse(NSNull()), .off)
    }

    func test_parse_acceptsTheTwoWireNames() {
        XCTAssertEqual(AXTree.Mode.parse("none"), .off)
        XCTAssertEqual(AXTree.Mode.parse("perBatch"), .perBatch)
    }

    /// Rejected, not quietly read as `none`. `perStep` is the interesting one: it is
    /// a real mode in the tool this idea came from, so a caller can plausibly write
    /// it, and accepting it silently would mean promising a cache simpilot never had.
    func test_parse_rejectsAnythingElse() {
        for raw in ["perStep", "off", "PERBATCH", "perbatch", "", "true"] {
            XCTAssertNil(AXTree.Mode.parse(raw), "\(raw) must be rejected")
        }
        XCTAssertNil(AXTree.Mode.parse(1))
        XCTAssertNil(AXTree.Mode.parse(true))
        XCTAssertNil(AXTree.Mode.parse(["perBatch"]))
    }

    // MARK: - Which routes end a cached tree's life
    //
    // Classification itself is enforced by the compiler: `Router.route` takes
    // `mutates:` with no default. What is left to check is the lookup — in
    // particular the direction it fails in.

    private func router() throws -> Router {
        Router(config: try AgentConfig.resolve(env: [:]))
    }

    func test_changesScreen_readOnlyRoutesKeepTheTree() throws {
        let router = try router()
        XCTAssertFalse(router.changesScreen(method: "GET", path: "/elements"))
        XCTAssertFalse(router.changesScreen(method: "POST", path: "/assert"))
    }

    func test_changesScreen_gesturesEndIt() throws {
        let router = try router()
        XCTAssertTrue(router.changesScreen(method: "POST", path: "/tap"))
        XCTAssertTrue(router.changesScreen(method: "POST", path: "/scroll-to"))
    }

    /// The safe default has to be this way round. An unregistered path must cost a
    /// fetch, never a coordinate taken off the previous screen. The `GET`/`POST`
    /// pairs matter too: `GET /clipboard` and `POST /clipboard` are one path with
    /// two answers, so the lookup may not key on the path alone.
    func test_changesScreen_isTrueForAnythingUnregistered() throws {
        let router = try router()
        XCTAssertTrue(router.changesScreen(method: "POST", path: "/not-a-route"))
        XCTAssertTrue(router.changesScreen(method: "PUT", path: "/elements"))
        XCTAssertTrue(router.changesScreen(method: "get", path: "/elements"))
        XCTAssertFalse(router.changesScreen(method: "GET", path: "/clipboard"))
        XCTAssertTrue(router.changesScreen(method: "POST", path: "/clipboard"))
    }

    // MARK: - Source scans
    //
    // Both properties below are about *where* code sits, which a live simulator
    // could not demonstrate either — the same last-resort technique as the wiring
    // scans in `ListClusterTests` and `ErrorHintTests`.

    private static let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

    /// Every non-test source file in the agent, read once for all the scans below
    /// and stripped of whole-line comments — `DebugDescriptionParser`'s header
    /// names `XCUIElement.debugDescription` in prose, and a scan that made a doc
    /// comment fail would be a test about wording.
    private static let sources: [String: String] = {
        let root = sourceDirectory
        let paths = (try? FileManager.default.subpathsOfDirectory(atPath: root.path)) ?? []
        return paths
            .filter { $0.hasSuffix(".swift") && !$0.hasSuffix("Tests.swift") }
            .reduce(into: [:]) { result, path in
                guard let text = try? String(
                    contentsOf: root.appendingPathComponent(path), encoding: .utf8
                ) else { return }
                result[path] = text
                    .components(separatedBy: "\n")
                    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                    .joined(separator: "\n")
            }
    }()

    /// The files whose source contains `needle`, sorted.
    private func filesContaining(_ needle: String) -> [String] {
        XCTAssertGreaterThan(Self.sources.count, 40, "the scan found almost nothing — it is probably broken")
        return Self.sources.filter { $0.value.contains(needle) }.keys.sorted()
    }

    /// `AXTree` is only the choke point for as long as it is the *only* reader.
    /// A handler reaching for the app's `debugDescription` directly would keep
    /// working and quietly opt itself out of the cache, which is the kind of drift
    /// the single-owner rules elsewhere in this codebase exist to prevent.
    ///
    /// Matched on `.debugDescription` rather than `app.debugDescription` so a reader
    /// that spells its receiver differently is caught too — which is why
    /// `PredicateEvaluator` needs naming: the property it has is its own
    /// `CustomDebugStringConvertible` conformance, nothing to do with the tree.
    func test_onlyAXTreeReadsTheAppsDebugDescription() {
        XCTAssertEqual(
            filesContaining(".debugDescription"),
            ["Core/AXTree.swift", "Core/PredicateEvaluator.swift"],
            "these files read a debugDescription without going through AXTree.description(of:)"
        )
    }

    /// Activating an app replaces the whole screen, and it happens *inside* two
    /// commands that are correctly `mutates: false` — `GET /elements?bundleId=` and
    /// `GET /source?bundleId=` activate and then read the tree back, so the
    /// batch-level drop is too late for them. `AppManager.enterForeground` is where
    /// that drop lives, and it is only the one place for as long as nothing else
    /// assigns `currentBundleId`.
    func test_theForegroundAppChangesInExactlyOnePlace() {
        let source = Self.sources["Core/AppManager.swift"] ?? ""
        XCTAssertEqual(
            source.components(separatedBy: "currentBundleId = ").count - 1, 1,
            "the foreground app is set somewhere other than AppManager.enterForeground, "
                + "so a tree cached for the previous app can survive the switch"
        )
        XCTAssertTrue(source.contains("AXTree.invalidate()"), "enterForeground must drop the tree")
    }

    /// A command that moves the UI and then reads it back has to drop the tree in
    /// between, and `AXTree.settle` is the one way to say so. Those commands are
    /// exactly the ones that wait for the UI to settle, so requiring every sleep in
    /// the agent to go through `settle` turns "did someone remember" into a scan
    /// that fails on the *next* such site rather than pinning the three that exist.
    ///
    /// A sleep that has nothing to do with the UI belongs in the exceptions below,
    /// with its reason — the same shape as `ErrorHint.deliberatelyWithoutHint`.
    func test_everySleepInTheAgentDropsTheTree() {
        let exceptions: [String: String] = [:]
        XCTAssertEqual(
            filesContaining("Thread.sleep").filter { exceptions[$0] == nil },
            ["Core/AXTree.swift"],
            "a sleep outside AXTree.settle: if it follows a UI change, call "
                + "AXTree.settle instead; if it has nothing to do with the screen, "
                + "name it in `exceptions` with the reason"
        )
    }
}
