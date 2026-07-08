import XCTest
@testable import simpilot

/// Coverage for `ButtonCommand.kebabToCamel` (improvement-plan Part B).
///
/// The CLI accepts kebab-case (`volume-up`) to match `rotate landscape-left`
/// and forwards the agent's camelCase wire name (`volumeUp`).
final class ButtonCommandTests: XCTestCase {

    func test_kebabToCamel_hyphenatedBecomesCamel() {
        XCTAssertEqual(ButtonCommand.kebabToCamel("volume-up"), "volumeUp")
        XCTAssertEqual(ButtonCommand.kebabToCamel("volume-down"), "volumeDown")
        XCTAssertEqual(ButtonCommand.kebabToCamel("play-pause"), "playPause")
    }

    func test_kebabToCamel_singleTokenUnchanged() {
        XCTAssertEqual(ButtonCommand.kebabToCamel("home"), "home")
        XCTAssertEqual(ButtonCommand.kebabToCamel("menu"), "menu")
        XCTAssertEqual(ButtonCommand.kebabToCamel("select"), "select")
    }
}
