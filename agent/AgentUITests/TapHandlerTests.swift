import XCTest

/// Coverage for `TapHandler.tapPoint` (improvement-plan A4).
///
/// Before A4 the switch/toggle trailing-edge offset lived inline in the
/// debugDescription fast path only; the poller path (taken whenever
/// `tap --timeout` / `wait_until` is set) center-tapped and so failed to flip
/// SwiftUI Toggles. Both paths now route through `tapPoint`, so these tests
/// lock the shared arithmetic that keeps the two paths in agreement.
final class TapHandlerTests: XCTestCase {

    private func found(
        type: String,
        x: Double, y: Double, w: Double, h: Double
    ) -> DebugDescriptionParser.FoundElement {
        DebugDescriptionParser.FoundElement(
            type: type, label: "L", identifier: "id", value: "",
            centerX: x + w / 2, centerY: y + h / 2,
            frame: (x: x, y: y, w: w, h: h), enabled: true,
            matchCount: 1, hittable: nil
        )
    }

    func test_tapPoint_switch_offsetsToTrailingEdge() {
        let element = found(type: "switch", x: 0, y: 100, w: 300, h: 44)
        let point = TapHandler.tapPoint(for: element)
        XCTAssertEqual(point.x, 300 - TapHandler.switchTapInset) // x + w - inset
        XCTAssertEqual(point.y, element.centerY)
    }

    func test_tapPoint_toggle_offsetsToTrailingEdge() {
        let element = found(type: "toggle", x: 10, y: 0, w: 200, h: 44)
        let point = TapHandler.tapPoint(for: element)
        XCTAssertEqual(point.x, 10 + 200 - TapHandler.switchTapInset)
        XCTAssertEqual(point.y, element.centerY)
    }

    func test_tapPoint_button_usesCenter() {
        let element = found(type: "button", x: 0, y: 0, w: 100, h: 40)
        let point = TapHandler.tapPoint(for: element)
        XCTAssertEqual(point.x, element.centerX)
        XCTAssertEqual(point.y, element.centerY)
    }

    /// The offset must land inside the row (to the left of the right edge), not
    /// beyond it — a regression that pushed the tap off-element would silently
    /// miss the control.
    func test_tapPoint_switch_staysInsideFrame() {
        let element = found(type: "switch", x: 50, y: 0, w: 120, h: 44)
        let point = TapHandler.tapPoint(for: element)
        XCTAssertLessThan(point.x, element.frame.x + element.frame.w)
        XCTAssertGreaterThan(point.x, element.frame.x)
    }
}
