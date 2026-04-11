import XCTest
@testable import simpilot

/// Tests `StartCommand.resolveStart` — the parse+validate+priority-chain step
/// that owns:
///   1. `--clone`/`--create` count invariants (positive integers, mutually exclusive)
///   2. the default-device priority chain (explicit > env > booted > fallback)
///   3. `--udid` <-> `--device` consistency + simulator-only scope
///
/// The function is pure: `SimctlLookup` is injected so tests never spawn
/// `xcrun simctl` subprocesses. `SimctlLookup.empty` reaches the env/fallback
/// branches deterministically.
final class StartCommandTests: XCTestCase {

    // MARK: - --clone / --create invariants

    func testNoFlagsFallsBackToHardcodedDefault() throws {
        let resolved = try StartCommand.resolveStart(args: [], env: [:], lookup: .empty)
        XCTAssertEqual(resolved.deviceName, "iPhone 17 Pro")
        XCTAssertEqual(resolved.resolvedVia, .fallback)
        XCTAssertNil(resolved.multiMode)
    }

    func testDeviceFlagOverridesDefault() throws {
        let resolved = try StartCommand.resolveStart(
            args: ["--device", "iPhone Air"],
            env: [:],
            lookup: .empty
        )
        XCTAssertEqual(resolved.deviceName, "iPhone Air")
        XCTAssertEqual(resolved.resolvedVia, .explicitDevice)
        XCTAssertNil(resolved.multiMode)
    }

    func testCloneWithPositiveCount() throws {
        let resolved = try StartCommand.resolveStart(
            args: ["--clone", "3"],
            env: [:],
            lookup: .empty
        )
        XCTAssertEqual(resolved.multiMode, .clone(3))
    }

    func testCloneWithoutValueDefaultsToOne() throws {
        let resolved = try StartCommand.resolveStart(
            args: ["--clone"],
            env: [:],
            lookup: .empty
        )
        XCTAssertEqual(resolved.multiMode, .clone(1))
    }

    func testCreateWithPositiveCount() throws {
        let resolved = try StartCommand.resolveStart(
            args: ["--create", "2"],
            env: [:],
            lookup: .empty
        )
        XCTAssertEqual(resolved.multiMode, .create(2))
    }

    func testCloneZeroIsRejected() {
        XCTAssertThrowsError(
            try StartCommand.resolveStart(args: ["--clone", "0"], env: [:], lookup: .empty)
        ) { error in
            assertInvalidArgs(error, contains: "--clone")
            assertInvalidArgs(error, contains: "positive")
            assertInvalidArgs(error, contains: "0")
        }
    }

    func testCloneNegativeIsRejected() {
        XCTAssertThrowsError(
            try StartCommand.resolveStart(args: ["--clone", "-3"], env: [:], lookup: .empty)
        ) { error in
            assertInvalidArgs(error, contains: "--clone")
            assertInvalidArgs(error, contains: "positive")
            assertInvalidArgs(error, contains: "-3")
        }
    }

    func testCreateZeroIsRejected() {
        XCTAssertThrowsError(
            try StartCommand.resolveStart(args: ["--create", "0"], env: [:], lookup: .empty)
        ) { error in
            assertInvalidArgs(error, contains: "--create")
            assertInvalidArgs(error, contains: "positive")
        }
    }

    func testCloneAndCreateMutuallyExclusive() {
        XCTAssertThrowsError(
            try StartCommand.resolveStart(
                args: ["--clone", "2", "--create", "2"],
                env: [:],
                lookup: .empty
            )
        ) { error in
            assertInvalidArgs(error, contains: "mutually exclusive")
        }
    }

    func testCloneFooRejectedAsNonInteger() {
        XCTAssertThrowsError(
            try StartCommand.resolveStart(args: ["--clone", "foo"], env: [:], lookup: .empty)
        ) { error in
            assertInvalidArgs(error, contains: "--clone")
            assertInvalidArgs(error, contains: "foo")
        }
    }

    // MARK: - Priority chain: env / booted / fallback

    func testEnvDefaultDeviceWhenNoFlags() throws {
        let resolved = try StartCommand.resolveStart(
            args: [],
            env: ["SIMPILOT_DEFAULT_DEVICE": "iPhone Air"],
            lookup: .empty
        )
        XCTAssertEqual(resolved.deviceName, "iPhone Air")
        XCTAssertEqual(resolved.resolvedVia, .env)
        XCTAssertNil(resolved.simulatorUDID)
    }

    func testEmptyEnvStringIsIgnored() throws {
        // Whitespace-only SIMPILOT_DEFAULT_DEVICE should be treated as unset
        // so we keep falling through to the booted / fallback slot.
        let resolved = try StartCommand.resolveStart(
            args: [],
            env: ["SIMPILOT_DEFAULT_DEVICE": "   "],
            lookup: .empty
        )
        XCTAssertEqual(resolved.deviceName, "iPhone 17 Pro")
        XCTAssertEqual(resolved.resolvedVia, .fallback)
    }

    func testExplicitDeviceBeatsEnv() throws {
        let resolved = try StartCommand.resolveStart(
            args: ["--device", "iPad Pro 13-inch (M5)"],
            env: ["SIMPILOT_DEFAULT_DEVICE": "iPhone Air"],
            lookup: .empty
        )
        XCTAssertEqual(resolved.deviceName, "iPad Pro 13-inch (M5)")
        XCTAssertEqual(resolved.resolvedVia, .explicitDevice)
    }

    func testBootedSimUsedWhenNoFlagsNoEnv() throws {
        let lookup = StartCommand.SimctlLookup(
            firstBooted: { ("UDID-BOOTED", "iPhone 16 Pro") },
            deviceName: { _ in nil }
        )
        let resolved = try StartCommand.resolveStart(args: [], env: [:], lookup: lookup)
        XCTAssertEqual(resolved.deviceName, "iPhone 16 Pro")
        XCTAssertEqual(resolved.simulatorUDID, "UDID-BOOTED")
        XCTAssertEqual(resolved.resolvedVia, .booted)
    }

    func testEnvBeatsBootedSim() throws {
        let lookup = StartCommand.SimctlLookup(
            firstBooted: { ("UDID-BOOTED", "iPhone 16 Pro") },
            deviceName: { _ in nil }
        )
        let resolved = try StartCommand.resolveStart(
            args: [],
            env: ["SIMPILOT_DEFAULT_DEVICE": "iPhone Air"],
            lookup: lookup
        )
        XCTAssertEqual(resolved.deviceName, "iPhone Air")
        XCTAssertEqual(resolved.resolvedVia, .env)
        // env branch doesn't pre-resolve the UDID — runSingle will do a
        // name-based simctl lookup when it actually launches.
        XCTAssertNil(resolved.simulatorUDID)
    }

    // MARK: - --udid branch

    func testUdidResolvesNameFromSimctl() throws {
        let lookup = StartCommand.SimctlLookup(
            firstBooted: { nil },
            deviceName: { udid in
                XCTAssertEqual(udid, "UDID-X")
                return "iPhone 17 Pro Max"
            }
        )
        let resolved = try StartCommand.resolveStart(
            args: ["--udid", "UDID-X"],
            env: [:],
            lookup: lookup
        )
        XCTAssertEqual(resolved.deviceName, "iPhone 17 Pro Max")
        XCTAssertEqual(resolved.simulatorUDID, "UDID-X")
        XCTAssertEqual(resolved.resolvedVia, .explicitUdid)
    }

    func testUdidPointingToUnknownUdidIsRejected() {
        XCTAssertThrowsError(
            try StartCommand.resolveStart(
                args: ["--udid", "UNKNOWN"],
                env: [:],
                lookup: .empty
            )
        ) { error in
            assertInvalidArgs(error, contains: "--udid")
            assertInvalidArgs(error, contains: "UNKNOWN")
            assertInvalidArgs(error, contains: "--device")
        }
    }

    func testUdidAndDeviceMatchingNameIsAccepted() throws {
        let lookup = StartCommand.SimctlLookup(
            firstBooted: { nil },
            deviceName: { _ in "iPhone Air" }
        )
        let resolved = try StartCommand.resolveStart(
            args: ["--udid", "UDID-X", "--device", "iPhone Air"],
            env: [:],
            lookup: lookup
        )
        XCTAssertEqual(resolved.deviceName, "iPhone Air")
        XCTAssertEqual(resolved.resolvedVia, .explicitUdid)
    }

    func testUdidAndDeviceMismatchIsRejected() {
        let lookup = StartCommand.SimctlLookup(
            firstBooted: { nil },
            deviceName: { _ in "iPhone Air" }
        )
        XCTAssertThrowsError(
            try StartCommand.resolveStart(
                args: ["--udid", "UDID-X", "--device", "iPhone 16 Pro"],
                env: [:],
                lookup: lookup
            )
        ) { error in
            assertInvalidArgs(error, contains: "iPhone Air")
            assertInvalidArgs(error, contains: "iPhone 16 Pro")
        }
    }

    func testUdidWithCloneRedirectsToNameBasedMulti() throws {
        // `--udid` + `--clone` is a graceful redirect: `resolveStart` reverse-
        // looks up the name so `runMulti`'s name-based `findDevice` sees the
        // exact device the user picked by UDID.
        let lookup = StartCommand.SimctlLookup(
            firstBooted: { nil },
            deviceName: { _ in "iPhone Air" }
        )
        let resolved = try StartCommand.resolveStart(
            args: ["--udid", "UDID-X", "--clone", "2"],
            env: [:],
            lookup: lookup
        )
        XCTAssertEqual(resolved.deviceName, "iPhone Air")
        XCTAssertEqual(resolved.multiMode, .clone(2))
        XCTAssertEqual(resolved.resolvedVia, .explicitUdid)
    }

    // MARK: - launchTarget (xcodebuild destination + registry UDID)

    // Invariant locked in here: whenever a concrete simulator UDID is known,
    // the xcodebuild `-destination` must anchor to that UDID (`id=<UDID>`),
    // not the display name. Name-based destinations let xcodebuild pick a
    // different device than the one whose UDID we wrote the port file for
    // when two simulators share a name, stranding the agent's `/health`.

    func testLaunchTargetSimulatorUsesIdFormat() {
        let target = StartCommand.launchTarget(
            for: .simulator(udid: "ABC-123"),
            deviceName: "iPhone Air"
        )
        XCTAssertEqual(target.destination, "id=ABC-123")
        XCTAssertEqual(target.udid, "ABC-123")
        XCTAssertFalse(target.isPhysical)
    }

    func testLaunchTargetSimulatorIgnoresDeviceNameForDestination() {
        // Same underlying UDID, different display names → destination must
        // still anchor to the UDID so duplicate-named sims are disambiguated.
        let targetA = StartCommand.launchTarget(
            for: .simulator(udid: "ABC-123"),
            deviceName: "iPhone Air"
        )
        let targetB = StartCommand.launchTarget(
            for: .simulator(udid: "ABC-123"),
            deviceName: "totally unrelated label"
        )
        XCTAssertEqual(targetA.destination, targetB.destination)
        XCTAssertEqual(targetA.destination, "id=ABC-123")
    }

    func testLaunchTargetPhysicalUsesPlatformAndId() {
        let device = DeviceHelper.PhysicalDevice(
            udid: "PHYS-456",
            name: "My iPhone",
            platform: "iOS",
            hostname: "my-iphone.coredevice.local"
        )
        let target = StartCommand.launchTarget(
            for: .physical(device: device),
            deviceName: "My iPhone"
        )
        XCTAssertEqual(target.destination, "platform=iOS,id=PHYS-456")
        XCTAssertEqual(target.udid, "PHYS-456")
        XCTAssertTrue(target.isPhysical)
    }

    func testLaunchTargetPhysicalVisionProMapsXrOS() {
        let device = DeviceHelper.PhysicalDevice(
            udid: "VP-789",
            name: "My Vision Pro",
            platform: "xrOS",
            hostname: "vp.coredevice.local"
        )
        let target = StartCommand.launchTarget(
            for: .physical(device: device),
            deviceName: "My Vision Pro"
        )
        XCTAssertEqual(target.destination, "platform=visionOS,id=VP-789")
    }

    func testLaunchTargetUnknownFallsBackToPlatformAndName() {
        // No UDID anchor → last-resort name-based destination with the
        // name-heuristic platform guess. `udid` is empty because we don't
        // have one to record in the agent registry.
        let target = StartCommand.launchTarget(
            for: .unknown,
            deviceName: "iPhone 17 Pro"
        )
        XCTAssertEqual(target.destination, "platform=iOS Simulator,name=iPhone 17 Pro")
        XCTAssertEqual(target.udid, "")
        XCTAssertFalse(target.isPhysical)
    }

    func testLaunchTargetUnknownVisionDeviceHeuristic() {
        let target = StartCommand.launchTarget(
            for: .unknown,
            deviceName: "Apple Vision Pro"
        )
        XCTAssertEqual(target.destination, "platform=visionOS Simulator,name=Apple Vision Pro")
    }

    // MARK: - Helpers

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
