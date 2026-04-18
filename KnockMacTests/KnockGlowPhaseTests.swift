import XCTest
@testable import KnockMac

final class KnockGlowPhaseTests: XCTestCase {

    // MARK: - Opacity envelope

    func testOpacityZeroBeforeStart() {
        XCTAssertEqual(glowPhase(elapsed: -0.1).opacity, 0, accuracy: 0.001)
    }

    func testOpacityZeroAtZero() {
        XCTAssertEqual(glowPhase(elapsed: 0.0).opacity, 0, accuracy: 0.001)
    }

    func testOpacityOneAtFadeInEnd() {
        XCTAssertEqual(glowPhase(elapsed: 0.25).opacity, 1, accuracy: 0.001)
    }

    func testOpacityOneDuringHold() {
        XCTAssertEqual(glowPhase(elapsed: 0.75).opacity, 1, accuracy: 0.001)
        XCTAssertEqual(glowPhase(elapsed: 1.30).opacity, 1, accuracy: 0.001)
    }

    func testOpacityZeroAtEnd() {
        XCTAssertEqual(glowPhase(elapsed: 1.55).opacity, 0, accuracy: 0.001)
    }

    func testOpacityZeroAfterEnd() {
        XCTAssertEqual(glowPhase(elapsed: 5.0).opacity, 0, accuracy: 0.001)
    }

    func testOpacityMonotonicallyIncreasesDuringFadeIn() {
        let a = glowPhase(elapsed: 0.05).opacity
        let b = glowPhase(elapsed: 0.15).opacity
        let c = glowPhase(elapsed: 0.24).opacity
        XCTAssertLessThan(a, b)
        XCTAssertLessThan(b, c)
    }

    func testOpacityMonotonicallyDecreasesDuringFadeOut() {
        let a = glowPhase(elapsed: 1.33).opacity
        let b = glowPhase(elapsed: 1.42).opacity
        let c = glowPhase(elapsed: 1.52).opacity
        XCTAssertGreaterThan(a, b)
        XCTAssertGreaterThan(b, c)
    }

    // MARK: - Scale envelope

    func testScaleStartsAt1_05() {
        XCTAssertEqual(glowPhase(elapsed: 0.0).scale, 1.05, accuracy: 0.001)
    }

    func testScaleReaches1_0AtFadeInEnd() {
        XCTAssertEqual(glowPhase(elapsed: 0.25).scale, 1.0, accuracy: 0.001)
    }

    func testScaleStaysAt1_0DuringHold() {
        XCTAssertEqual(glowPhase(elapsed: 1.0).scale, 1.0, accuracy: 0.001)
    }

    func testScaleStaysAt1_0DuringFadeOut() {
        XCTAssertEqual(glowPhase(elapsed: 1.42).scale, 1.0, accuracy: 0.001)
    }

    // MARK: - Rotation (unwrapped)

    func testRotationZeroAtZero() {
        XCTAssertEqual(glowPhase(elapsed: 0.0).rotation.radians, 0, accuracy: 0.001)
    }

    func testRotationGrowsWithElapsed() {
        let r1 = glowPhase(elapsed: 0.1).rotation.radians
        let r2 = glowPhase(elapsed: 0.5).rotation.radians
        let r3 = glowPhase(elapsed: 1.0).rotation.radians
        XCTAssertGreaterThan(r2, r1)
        XCTAssertGreaterThan(r3, r2)
    }

    func testRotationIsLinearInTime() {
        // 360°/2.5s = 2π/2.5 rad/s
        let expectedRate = (2 * .pi) / 2.5
        XCTAssertEqual(glowPhase(elapsed: 1.0).rotation.radians, expectedRate, accuracy: 0.001)
        XCTAssertEqual(glowPhase(elapsed: 2.0).rotation.radians, 2 * expectedRate, accuracy: 0.001)
    }
}
