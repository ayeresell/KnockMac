import XCTest
@testable import KnockMac

final class KnockGlowPhaseTests: XCTestCase {

    // Envelope: 0.00 → 0.08 fade-in (ease-out quad), 0.08 → 0.23 hold,
    // 0.23 → 0.40 fade-out (ease-in quad), 0 after 0.40 and before 0.

    // MARK: - Boundaries

    func testOpacityZeroBeforeStart() {
        XCTAssertEqual(glowPhase(elapsed: -0.1).opacity, 0, accuracy: 0.001)
    }

    func testOpacityZeroAtZero() {
        XCTAssertEqual(glowPhase(elapsed: 0.0).opacity, 0, accuracy: 0.001)
    }

    func testOpacityOneAtFadeInEnd() {
        XCTAssertEqual(glowPhase(elapsed: 0.08).opacity, 1, accuracy: 0.001)
    }

    func testOpacityOneAtHoldMidpoint() {
        XCTAssertEqual(glowPhase(elapsed: 0.15).opacity, 1, accuracy: 0.001)
    }

    func testOpacityOneAtHoldEnd() {
        XCTAssertEqual(glowPhase(elapsed: 0.23).opacity, 1, accuracy: 0.001)
    }

    func testOpacityZeroAtTotalEnd() {
        XCTAssertEqual(glowPhase(elapsed: 0.40).opacity, 0, accuracy: 0.001)
    }

    func testOpacityZeroAfterTotalEnd() {
        XCTAssertEqual(glowPhase(elapsed: 1.0).opacity, 0, accuracy: 0.001)
    }

    // MARK: - Easing midpoints
    //
    // Fade-in ease-out quad at t=0.5 → 1 − (1−0.5)² = 0.75.
    //   elapsed = 0.04 → t = 0.5 → opacity ≈ 0.75
    // Fade-out ease-in quad at t=0.5 → 1 − (0.5)² = 0.75.
    //   elapsed = 0.315 → t = (0.315-0.23)/(0.40-0.23) = 0.5 → opacity ≈ 0.75

    func testFadeInMidpoint() {
        XCTAssertEqual(glowPhase(elapsed: 0.04).opacity, 0.75, accuracy: 0.01)
    }

    func testFadeOutMidpoint() {
        XCTAssertEqual(glowPhase(elapsed: 0.315).opacity, 0.75, accuracy: 0.01)
    }

    // MARK: - Monotonicity

    func testOpacityMonotonicallyIncreasesDuringFadeIn() {
        let a = glowPhase(elapsed: 0.01).opacity
        let b = glowPhase(elapsed: 0.04).opacity
        let c = glowPhase(elapsed: 0.07).opacity
        XCTAssertLessThan(a, b)
        XCTAssertLessThan(b, c)
    }

    func testOpacityMonotonicallyDecreasesDuringFadeOut() {
        let a = glowPhase(elapsed: 0.25).opacity
        let b = glowPhase(elapsed: 0.31).opacity
        let c = glowPhase(elapsed: 0.38).opacity
        XCTAssertGreaterThan(a, b)
        XCTAssertGreaterThan(b, c)
    }
}
