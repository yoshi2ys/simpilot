import XCTest
@testable import simpilot

/// Tests `SimctlHelper`'s pure teardown-decision helper.
///
/// The side-effecting half (`teardownRunner`, `sweepOrphanRunners`) is not unit
/// tested here — it shells out to `xcrun simctl` against real devices, which
/// belongs in a smoke test. What this file pins is the branching those two share
/// with `StopCommand.teardownAgent` and `StartCommand.rollback`: which `simctl`
/// steps a given (udid, isPhysical, isClone) triple earns.
final class SimctlHelperTests: XCTestCase {

    // MARK: - teardownSteps

    /// A terminated-but-still-installed runner is what `launchd_sim` keeps
    /// relaunching in the background, aborting in dyld (no `XCTest.framework`
    /// outside `xcodebuild test`) and popping a macOS crash dialog each time.
    /// `terminate` alone is therefore not a complete teardown.
    func testSimulatorAgentTerminatesAndUninstallsRunner() {
        XCTAssertEqual(
            SimctlHelper.teardownSteps(udid: "A", isPhysical: false, isClone: false),
            [.terminateRunner, .uninstallRunner]
        )
    }

    /// Deleting the device takes the runner app with it, so uninstalling first
    /// would be wasted work — but the runner must still be terminated.
    func testCloneAgentDeletesDeviceInsteadOfUninstalling() {
        XCTAssertEqual(
            SimctlHelper.teardownSteps(udid: "A", isPhysical: false, isClone: true),
            [.terminateRunner, .deleteClone]
        )
    }

    /// Physical devices are driven by `devicectl`; running `simctl` against a
    /// physical UDID would either no-op or hit an unrelated simulator.
    func testPhysicalAgentGetsNoSimctlSteps() {
        XCTAssertEqual(
            SimctlHelper.teardownSteps(udid: "00008120-ABC", isPhysical: true, isClone: false),
            []
        )
    }

    /// An empty UDID would make `simctl` operate on the booted device, which is
    /// not the one the caller meant.
    func testEmptyUdidGetsNoSimctlSteps() {
        XCTAssertEqual(
            SimctlHelper.teardownSteps(udid: "", isPhysical: false, isClone: false),
            []
        )
    }

    /// Uninstall and delete are mutually exclusive across every input, so no
    /// caller can ever pay for both.
    func testUninstallAndDeleteAreNeverBothEmitted() {
        for isPhysical in [true, false] {
            for isClone in [true, false] {
                for udid in ["A", ""] {
                    let steps = SimctlHelper.teardownSteps(
                        udid: udid, isPhysical: isPhysical, isClone: isClone
                    )
                    XCTAssertFalse(
                        steps.contains(.uninstallRunner) && steps.contains(.deleteClone),
                        "udid=\(udid) isPhysical=\(isPhysical) isClone=\(isClone) emitted both"
                    )
                }
            }
        }
    }

    /// Whenever any `simctl` work happens at all, the runner is terminated first
    /// — freeing the port before the app is removed or the device deleted.
    func testTerminateAlwaysPrecedesRemoval() {
        for isClone in [true, false] {
            let steps = SimctlHelper.teardownSteps(udid: "A", isPhysical: false, isClone: isClone)
            XCTAssertEqual(steps.first, .terminateRunner, "isClone=\(isClone)")
            XCTAssertEqual(steps.count, 2, "isClone=\(isClone)")
        }
    }

    // MARK: - runnerBundleID

    /// The bundle id is what scopes every teardown to simpilot's own runner. A
    /// `pgrep`-style pattern would have to guess; this must stay exact.
    func testRunnerBundleIDIsExact() {
        XCTAssertEqual(SimctlHelper.runnerBundleID, "dev.yoshi.simpilot.AgentUITests.xctrunner")
    }
}
