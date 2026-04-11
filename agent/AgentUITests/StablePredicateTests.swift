import XCTest

final class StablePredicateTests: XCTestCase {
    private let frameA: (x: Double, y: Double, w: Double, h: Double) = (16, 293.3, 370, 52)
    private let frameB: (x: Double, y: Double, w: Double, h: Double) = (16, 345.3, 370, 52)

    func test_firstObservation_doesNotSatisfy() {
        var state = StablePredicate.State.initial
        let satisfied = StablePredicate.advance(&state, observedFrame: frameA)
        XCTAssertFalse(satisfied)
        XCTAssertEqual(state.count, 1)
        XCTAssertNotNil(state.prevFrame)
    }

    func test_twoSameFrameObservations_satisfiesAtN2() {
        var state = StablePredicate.State.initial
        _ = StablePredicate.advance(&state, observedFrame: frameA)
        let satisfied = StablePredicate.advance(&state, observedFrame: frameA)
        XCTAssertTrue(satisfied)
        XCTAssertEqual(state.count, StablePredicate.requiredCount)
    }

    func test_frameChange_resetsCountToOne() {
        var state = StablePredicate.State.initial
        _ = StablePredicate.advance(&state, observedFrame: frameA)
        _ = StablePredicate.advance(&state, observedFrame: frameA) // count=2, would be satisfied
        let satisfied = StablePredicate.advance(&state, observedFrame: frameB)
        XCTAssertFalse(satisfied)
        XCTAssertEqual(state.count, 1)
        XCTAssertEqual(state.prevFrame, StablePredicate.Frame(frameB))
    }

    func test_elementDisappears_resetsStateToInitial() {
        var state = StablePredicate.State.initial
        _ = StablePredicate.advance(&state, observedFrame: frameA)
        _ = StablePredicate.advance(&state, observedFrame: frameA) // would be satisfied
        let satisfied = StablePredicate.advance(&state, observedFrame: nil)
        XCTAssertFalse(satisfied)
        XCTAssertEqual(state, .initial)
    }

    func test_elementReappearsAfterDisappearance_restartsFromOne() {
        var state = StablePredicate.State.initial
        _ = StablePredicate.advance(&state, observedFrame: frameA)
        _ = StablePredicate.advance(&state, observedFrame: frameA)
        _ = StablePredicate.advance(&state, observedFrame: nil)
        // Re-appearance: first observation after reset must not satisfy, even
        // though the frame is identical to what we saw before disappearance.
        let satisfied = StablePredicate.advance(&state, observedFrame: frameA)
        XCTAssertFalse(satisfied)
        XCTAssertEqual(state.count, 1)
    }

    func test_threeSameFrameObservations_staysSatisfied() {
        var state = StablePredicate.State.initial
        _ = StablePredicate.advance(&state, observedFrame: frameA)
        _ = StablePredicate.advance(&state, observedFrame: frameA)
        let satisfied = StablePredicate.advance(&state, observedFrame: frameA)
        XCTAssertTrue(satisfied)
        XCTAssertEqual(state.count, 3)
    }

    // Sub-pixel differences count as frame changes: UIKit settles layouts
    // at integer points, so noise means the UI has not settled yet.
    func test_subPixelDifference_resetsCount() {
        var state = StablePredicate.State.initial
        _ = StablePredicate.advance(&state, observedFrame: frameA)
        let nudged: (x: Double, y: Double, w: Double, h: Double) =
            (frameA.x + 0.01, frameA.y, frameA.w, frameA.h)
        let satisfied = StablePredicate.advance(&state, observedFrame: nudged)
        XCTAssertFalse(satisfied)
        XCTAssertEqual(state.count, 1)
    }
}
