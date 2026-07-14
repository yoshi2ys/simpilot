import XCTest
@testable import simpilot

/// Coverage for `DeviceHelper.resolvePlatform` (A25).
///
/// The bug: when `devicectl`'s `hardwareProperties.platform` was missing, the
/// code guessed the platform from `osVersionNumber.hasPrefix("2")`, which
/// misclassified iOS 26/27 devices as visionOS. `resolvePlatform` replaces the
/// guess with an explicit allowlist — unknown or missing platforms must not be
/// silently mapped to "iOS" or "xrOS".
final class DeviceHelperTests: XCTestCase {

    func test_resolvePlatform_iOS() {
        XCTAssertEqual(DeviceHelper.resolvePlatform(hardwarePlatform: "iOS"), "iOS")
    }

    func test_resolvePlatform_xrOS() {
        XCTAssertEqual(DeviceHelper.resolvePlatform(hardwarePlatform: "xrOS"), "xrOS")
    }

    func test_resolvePlatform_missing_returnsNil() {
        XCTAssertNil(DeviceHelper.resolvePlatform(hardwarePlatform: nil))
    }

    func test_resolvePlatform_unknownString_returnsNil() {
        // Regression: an osVersionNumber like "26.0" previously fell through to
        // the "2".hasPrefix heuristic and was misclassified as visionOS.
        XCTAssertNil(DeviceHelper.resolvePlatform(hardwarePlatform: "watchOS"))
        XCTAssertNil(DeviceHelper.resolvePlatform(hardwarePlatform: ""))
    }
}
