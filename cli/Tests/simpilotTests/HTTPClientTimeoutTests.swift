import XCTest
@testable import simpilot

/// Coverage for the client/server timeout coordination (improvement-plan A5).
///
/// The bug: `simpilot wait 'X' --timeout 60` sends a 60s budget to the agent
/// but the HTTP client kept its default 30s deadline, aborting a healthy
/// long-running operation as `agent_unreachable`. `requestTimeout(forOperationBudget:)`
/// is the shared arithmetic that keeps the client waiting at least as long as
/// the agent will work.
final class HTTPClientTimeoutTests: XCTestCase {

    private func client(timeout: TimeInterval = 30) -> HTTPClient {
        HTTPClient(baseURL: "http://localhost:8222", timeout: timeout)
    }

    func test_requestTimeout_nilBudget_returnsNil() {
        // No budget → fall back to the client's own default timeout.
        XCTAssertNil(client().requestTimeout(forOperationBudget: nil))
    }

    func test_requestTimeout_smallBudget_keepsClientDefault() {
        // A short op must not shrink the client deadline below its default.
        XCTAssertEqual(client(timeout: 30).requestTimeout(forOperationBudget: 3), 30)
    }

    func test_requestTimeout_largeBudget_extendsBeyondDefault() {
        // `wait --timeout 60` → 60 + 5 buffer = 65, comfortably past the 30s default.
        XCTAssertEqual(client(timeout: 30).requestTimeout(forOperationBudget: 60), 65)
    }

    func test_requestTimeout_boundary_usesBufferedBudgetOnlyWhenLarger() {
        let c = client(timeout: 30)
        // 25 + 5 == 30 → tie stays at the default.
        XCTAssertEqual(c.requestTimeout(forOperationBudget: 25), 30)
        // 26 + 5 == 31 → just past the default.
        XCTAssertEqual(c.requestTimeout(forOperationBudget: 26), 31)
    }

    func test_requestTimeout_respectsHigherClientDefault() {
        // A global `--timeout 90` must not be lowered by a small op budget.
        XCTAssertEqual(client(timeout: 90).requestTimeout(forOperationBudget: 10), 90)
    }

    func test_operationBuffer_isFiveSeconds() {
        // Guards the buffer the arithmetic above assumes.
        XCTAssertEqual(HTTPClient.operationBuffer, 5)
    }

    // MARK: - scroll-to budget (A5 correctness: default swipe cap)

    func test_scrollToBudget_defaultsToAgentSwipeCapWhenUnset() {
        // No --max-swipes must still budget for the agent's default 10 swipes,
        // not fall back to a bare 30s that a ~30s scroll would race.
        XCTAssertEqual(
            ScrollToCommand.operationBudget(maxSwipes: nil),
            Double(ScrollToCommand.defaultMaxSwipes) * ScrollToCommand.perSwipeBudget
        )
        // That budget must clear the 30s client default once buffered.
        XCTAssertEqual(
            client(timeout: 30).requestTimeout(forOperationBudget: ScrollToCommand.operationBudget(maxSwipes: nil)),
            35
        )
    }

    func test_scrollToBudget_scalesWithExplicitSwipes() {
        XCTAssertEqual(ScrollToCommand.operationBudget(maxSwipes: 20), 60)
    }
}
