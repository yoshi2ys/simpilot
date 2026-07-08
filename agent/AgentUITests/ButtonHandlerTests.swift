import XCTest

/// Coverage for `ButtonHandler` (improvement-plan Part B).
///
/// Only the non-pressing paths are exercised: a missing name and an unknown
/// button both return before touching `XCUIDevice`/`XCUIRemote`, so they are
/// safe to assert in a unit test with no live UI session. The actual press is
/// left to on-device use.
final class ButtonHandlerTests: XCTestCase {

    private func responseString(forName name: Any?) -> String {
        var body: [String: Any] = [:]
        if let name { body["name"] = name }
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        let request = HTTPRequest(method: "POST", path: "/button", queryParams: [:], headers: [:], body: data)
        let response = ButtonHandler().handle(request)
        return String(data: response, encoding: .utf8) ?? ""
    }

    func test_handle_missingName_returnsInvalidRequest() {
        XCTAssertTrue(responseString(forName: nil).contains("\"invalid_request\""))
    }

    func test_handle_unknownButton_returnsInvalidArgs() {
        // lock/power has no public XCUITest API — must fail loud, not no-op.
        // A bad name on a button-capable platform is invalid_args (like Rotate),
        // reserving unsupported_platform for platforms with no buttons at all.
        let response = responseString(forName: "lock")
        XCTAssertTrue(response.contains("\"invalid_args\""))
        XCTAssertTrue(response.contains("Unknown button: lock"))
    }

    #if os(iOS)
    func test_supportedButtons_iOS_includeHome() {
        XCTAssertTrue(ButtonHandler.supportedButtons.contains("home"))
        // Volume buttons are physical-device-only — absent on the Simulator.
        #if targetEnvironment(simulator)
        XCTAssertFalse(ButtonHandler.supportedButtons.contains("volumeUp"))
        #else
        XCTAssertTrue(ButtonHandler.supportedButtons.contains("volumeUp"))
        XCTAssertTrue(ButtonHandler.supportedButtons.contains("volumeDown"))
        #endif
    }

    /// An unknown-button error must list the platform's valid names so callers
    /// can self-correct. `home` is present on every iOS environment.
    func test_unsupported_hintListsValidNames() {
        let response = responseString(forName: "square")
        XCTAssertTrue(response.contains("home"))
    }
    #endif
}
