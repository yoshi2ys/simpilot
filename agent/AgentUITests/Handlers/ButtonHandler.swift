import Foundation
import XCTest

/// `POST /button` — press a hardware button. iOS/iPadOS route to
/// `XCUIDevice.shared.press(_:)` (home / volume); tvOS routes to
/// `XCUIRemote.shared.press(_:)` (remote buttons). Buttons with no public
/// XCUITest API — lock/power, shake, Digital Crown — are intentionally absent
/// and report an error rather than silently no-op'ing (per the plan's "no
/// silent failure" theme). visionOS/watchOS expose no buttons here and report
/// `unsupported_platform` for every name.
final class ButtonHandler: @unchecked Sendable {
    func handle(_ request: HTTPRequest) -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let name = json["name"] as? String else {
            return HTTPResponseBuilder.error(
                "Missing 'name' in request body",
                code: "invalid_request"
            )
        }
        return Self.press(name: name)
    }

    /// Button names this platform can press, sorted. Empty on platforms with no
    /// supported hardware buttons. Exposed for tests and the error hint.
    static var supportedButtons: [String] { buttonNames.sorted() }

    /// Press `name`. A name this platform can't press is reported loudly:
    /// `invalid_args` (with the valid names) when the platform has buttons, or
    /// `unsupported_platform` when it has none — never a silent no-op. The
    /// platform-specific bits (which enum, which `press`) live only in
    /// `invocation(for:)`; the error/success envelope is shared here.
    static func press(name: String) -> Data {
        guard let invoke = invocation(for: name) else {
            if supportedButtons.isEmpty {
                return HTTPResponseBuilder.error(
                    "Hardware buttons are not supported on this platform",
                    code: "unsupported_platform"
                )
            }
            return HTTPResponseBuilder.error(
                "Unknown button: \(name). Use: \(supportedButtons.joined(separator: ", "))",
                code: "invalid_args"
            )
        }
        if let failure = catchObjCException(invoke) {
            return HTTPResponseBuilder.error("Button press failed: \(failure)", code: "button_failed", status: 500)
        }
        return HTTPResponseBuilder.json(["name": name])
    }

    #if os(tvOS)
    private static let remoteButtons: [String: XCUIRemote.Button] = [
        "menu": .menu, "playPause": .playPause, "select": .select,
        "up": .up, "down": .down, "left": .left, "right": .right, "home": .home,
    ]
    private static var buttonNames: [String] { Array(remoteButtons.keys) }
    private static func invocation(for name: String) -> (() -> Void)? {
        remoteButtons[name].map { button in { XCUIRemote.shared.press(button) } }
    }
    #elseif os(iOS)
    private static let deviceButtons: [String: XCUIDevice.Button] = {
        // The volume buttons exist only on a physical device; even *referencing*
        // `.volumeUp` / `.volumeDown` is a hard compile error under the
        // Simulator SDK, so they're gated out there and reported as unknown.
        var buttons: [String: XCUIDevice.Button] = ["home": .home]
        #if !targetEnvironment(simulator)
        buttons["volumeUp"] = .volumeUp
        buttons["volumeDown"] = .volumeDown
        #endif
        return buttons
    }()
    private static var buttonNames: [String] { Array(deviceButtons.keys) }
    private static func invocation(for name: String) -> (() -> Void)? {
        deviceButtons[name].map { button in { XCUIDevice.shared.press(button) } }
    }
    #else
    private static var buttonNames: [String] { [] }
    private static func invocation(for name: String) -> (() -> Void)? { nil }
    #endif
}
