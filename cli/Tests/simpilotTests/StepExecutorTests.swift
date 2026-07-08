import XCTest
@testable import simpilot

/// Coverage for `StepExecutor.isSuccess` (improvement-plan A22).
final class StepExecutorTests: XCTestCase {

    func test_isSuccess_trueWhenSuccessTrue() {
        XCTAssertTrue(StepExecutor.isSuccess(["success": true]))
    }

    func test_isSuccess_falseWhenSuccessFalse() {
        XCTAssertFalse(StepExecutor.isSuccess(["success": false]))
    }

    func test_isSuccess_falseWhenSuccessMissing() {
        // A malformed envelope with no `success` field must count as a failure,
        // not silently pass as success (A22).
        XCTAssertFalse(StepExecutor.isSuccess([:]))
        XCTAssertFalse(StepExecutor.isSuccess(["data": ["x": 1]]))
    }
}
